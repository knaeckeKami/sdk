// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/dart/element/type_provider.dart';
import 'package:analyzer/src/dart/element/type.dart';
import 'package:analyzer/src/generated/source.dart';
import 'package:meta/meta.dart';
import 'package:nnbd_migration/instrumentation.dart';
import 'package:nnbd_migration/nnbd_migration.dart';
import 'package:nnbd_migration/src/decorated_type.dart';
import 'package:nnbd_migration/src/nullability_node.dart';
import 'package:nnbd_migration/src/nullability_node_target.dart';
import 'package:nnbd_migration/src/potential_modification.dart';
import 'package:nnbd_migration/src/utilities/completeness_tracker.dart';
import 'package:nnbd_migration/src/utilities/hint_utils.dart';
import 'package:nnbd_migration/src/utilities/permissive_mode.dart';
import 'package:nnbd_migration/src/utilities/resolution_utils.dart';
import 'package:nnbd_migration/src/variables.dart';

import 'edge_origin.dart';

/// Visitor that builds nullability nodes based on visiting code to be migrated.
///
/// The return type of each `visit...` method is a [DecoratedType] indicating
/// the static type of the element declared by the visited node, along with the
/// constraint variables that will determine its nullability.  For `visit...`
/// methods that don't visit declarations, `null` will be returned.
class NodeBuilder extends GeneralizingAstVisitor<DecoratedType>
    with
        PermissiveModeVisitor<DecoratedType>,
        CompletenessTracker<DecoratedType> {
  /// Constraint variables and decorated types are stored here.
  final Variables _variables;

  @override
  final Source source;

  /// If the parameters of a function or method are being visited, the
  /// [DecoratedType]s of the function's named parameters that have been seen so
  /// far.  Otherwise `null`.
  Map<String, DecoratedType> _namedParameters;

  /// If the parameters of a function or method are being visited, the
  /// [DecoratedType]s of the function's positional parameters that have been
  /// seen so far.  Otherwise `null`.
  List<DecoratedType> _positionalParameters;

  /// If the child types of a node are being visited, the
  /// [NullabilityNodeTarget] that should be used in [visitTypeAnnotation].
  /// Otherwise `null`.
  NullabilityNodeTarget _target;

  final NullabilityMigrationListener /*?*/ listener;

  final NullabilityMigrationInstrumentation /*?*/ instrumentation;

  final NullabilityGraph _graph;

  final TypeProvider _typeProvider;

  NodeBuilder(this._variables, this.source, this.listener, this._graph,
      this._typeProvider,
      {this.instrumentation});

  @override
  DecoratedType visitCatchClause(CatchClause node) {
    DecoratedType exceptionType = node.exceptionType?.accept(this);
    if (node.exceptionParameter != null) {
      // If there is no `on Type` part of the catch clause, the type is dynamic.
      if (exceptionType == null) {
        var target = NullabilityNodeTarget.text('exception').withCodeRef(node);
        exceptionType = DecoratedType.forImplicitType(
            _typeProvider, _typeProvider.dynamicType, _graph, target);
        instrumentation?.implicitType(
            source, node.exceptionParameter, exceptionType);
      }
      _variables.recordDecoratedElementType(
          node.exceptionParameter.staticElement, exceptionType);
    }
    if (node.stackTraceParameter != null) {
      // The type of stack traces is always StackTrace (non-nullable).
      var target = NullabilityNodeTarget.text('stack trace').withCodeRef(node);
      var nullabilityNode = NullabilityNode.forInferredType(target);
      _graph.makeNonNullableUnion(nullabilityNode,
          StackTraceTypeOrigin(source, node.stackTraceParameter));
      var stackTraceType =
          DecoratedType(_typeProvider.stackTraceType, nullabilityNode);
      _variables.recordDecoratedElementType(
          node.stackTraceParameter.staticElement, stackTraceType);
      instrumentation?.implicitType(
          source, node.stackTraceParameter, stackTraceType);
    }
    node.stackTraceParameter?.accept(this);
    node.body?.accept(this);
    return null;
  }

  @override
  DecoratedType visitClassDeclaration(ClassDeclaration node) {
    node.metadata.accept(this);
    node.name.accept(this);
    node.typeParameters?.accept(this);
    node.nativeClause?.accept(this);
    node.members.accept(this);
    var classElement = node.declaredElement;
    _handleSupertypeClauses(node, classElement, node.extendsClause?.superclass,
        node.withClause, node.implementsClause, null);
    var constructors = classElement.constructors;
    if (constructors.length == 1) {
      var constructorElement = constructors[0];
      if (constructorElement.isSynthetic) {
        // Need to create a decorated type for the default constructor.
        var decoratedReturnType =
            _createDecoratedTypeForClass(classElement, node);
        var functionType = DecoratedType(constructorElement.type, _graph.never,
            returnType: decoratedReturnType,
            positionalParameters: const [],
            namedParameters: {});
        _variables.recordDecoratedElementType(constructorElement, functionType);
      }
    }
    return null;
  }

  @override
  DecoratedType visitClassTypeAlias(ClassTypeAlias node) {
    node.metadata.accept(this);
    node.name.accept(this);
    node.typeParameters?.accept(this);
    var classElement = node.declaredElement;
    _handleSupertypeClauses(node, classElement, node.superclass,
        node.withClause, node.implementsClause, null);
    for (var constructorElement in classElement.constructors) {
      assert(constructorElement.isSynthetic);
      var decoratedReturnType =
          _createDecoratedTypeForClass(classElement, node);
      var target = NullabilityNodeTarget.element(constructorElement);
      var functionType = DecoratedType.forImplicitFunction(
          _typeProvider, constructorElement.type, _graph.never, _graph, target,
          returnType: decoratedReturnType);
      _variables.recordDecoratedElementType(constructorElement, functionType);
    }
    return null;
  }

  @override
  DecoratedType visitCompilationUnit(CompilationUnit node) {
    _graph.migrating(node.declaredElement.library.source);
    _graph.migrating(node.declaredElement.source);
    return super.visitCompilationUnit(node);
  }

  @override
  DecoratedType visitConstructorDeclaration(ConstructorDeclaration node) {
    _handleExecutableDeclaration(
        node,
        node.declaredElement,
        node.metadata,
        null,
        null,
        node.parameters,
        node.initializers,
        node.body,
        node.redirectedConstructor);
    return null;
  }

  @override
  DecoratedType visitDeclaredIdentifier(DeclaredIdentifier node) {
    node.metadata.accept(this);
    DecoratedType type = node.type?.accept(this);
    if (node.identifier != null) {
      if (type == null) {
        var declaredElement = node.declaredElement;
        var target = NullabilityNodeTarget.element(declaredElement);
        type = DecoratedType.forImplicitType(
            _typeProvider, declaredElement.type, _graph, target);
        instrumentation?.implicitType(source, node, type);
      }
      _variables.recordDecoratedElementType(
          node.identifier.staticElement, type);
    }
    return type;
  }

  @override
  DecoratedType visitDefaultFormalParameter(DefaultFormalParameter node) {
    var decoratedType = node.parameter.accept(this);
    if (node.defaultValue != null) {
      node.defaultValue.accept(this);
      return null;
    } else if (node.declaredElement.hasRequired) {
      return null;
    }
    if (decoratedType == null) {
      throw StateError('No type computed for ${node.parameter.runtimeType} '
          '(${node.parent.parent.toSource()}) offset=${node.offset}');
    }
    decoratedType.node.trackPossiblyOptional();
    _variables.recordPossiblyOptional(source, node, decoratedType.node);
    return null;
  }

  @override
  DecoratedType visitEnumDeclaration(EnumDeclaration node) {
    node.metadata.accept(this);
    node.name.accept(this);
    var classElement = node.declaredElement;
    _variables.recordDecoratedElementType(
        classElement, DecoratedType(classElement.thisType, _graph.never));

    makeNonNullNode(NullabilityNodeTarget target, [AstNode forNode]) {
      forNode ??= node;
      final graphNode = NullabilityNode.forInferredType(target);
      _graph.makeNonNullableUnion(graphNode, EnumValueOrigin(source, forNode));
      return graphNode;
    }

    for (var item in node.constants) {
      var declaredElement = item.declaredElement;
      var target = NullabilityNodeTarget.element(declaredElement);
      _variables.recordDecoratedElementType(declaredElement,
          DecoratedType(classElement.thisType, makeNonNullNode(target, item)));
    }
    final valuesGetter = classElement.getGetter('values');
    var valuesTarget = NullabilityNodeTarget.element(valuesGetter);
    _variables.recordDecoratedElementType(
        valuesGetter,
        DecoratedType(valuesGetter.type, makeNonNullNode(valuesTarget),
            returnType: DecoratedType(valuesGetter.returnType,
                makeNonNullNode(valuesTarget.returnType()),
                typeArguments: [
                  DecoratedType(classElement.thisType,
                      makeNonNullNode(valuesTarget.typeArgument(0)))
                ])));
    final indexGetter = classElement.getGetter('index');
    var indexTarget = NullabilityNodeTarget.element(indexGetter);
    _variables.recordDecoratedElementType(
        indexGetter,
        DecoratedType(indexGetter.type, makeNonNullNode(indexTarget),
            returnType: DecoratedType(indexGetter.returnType,
                makeNonNullNode(indexTarget.returnType()))));
    final toString = classElement.getMethod('toString');
    var toStringTarget = NullabilityNodeTarget.element(toString);
    _variables.recordDecoratedElementType(
        toString,
        DecoratedType(toString.type, makeNonNullNode(toStringTarget),
            returnType: DecoratedType(toString.returnType,
                makeNonNullNode(toStringTarget.returnType()))));
    return null;
  }

  @override
  DecoratedType visitExtensionDeclaration(ExtensionDeclaration node) {
    node.metadata.accept(this);
    node.typeParameters?.accept(this);
    var type = node.extendedType.accept(this);
    _variables.recordDecoratedElementType(node.declaredElement, type);
    node.members.accept(this);
    return null;
  }

  @override
  DecoratedType visitFieldFormalParameter(FieldFormalParameter node) {
    return _handleFormalParameter(
        node, node.type, node.typeParameters, node.parameters);
  }

  @override
  DecoratedType visitFormalParameterList(FormalParameterList node) {
    int index = 0;
    for (var parameter in node.parameters) {
      var element = parameter.declaredElement;
      NullabilityNodeTarget newTarget;
      if (_target == null) {
        newTarget = null;
      } else if (element.isNamed) {
        newTarget = _target.namedParameter(element.name);
      } else {
        newTarget = _target.positionalParameter(index++);
      }
      _pushNullabilityNodeTarget(newTarget, () => parameter.accept(this));
    }
    return null;
  }

  @override
  DecoratedType visitFunctionDeclaration(FunctionDeclaration node) {
    _handleExecutableDeclaration(
        node,
        node.declaredElement,
        node.metadata,
        node.returnType,
        node.functionExpression.typeParameters,
        node.functionExpression.parameters,
        null,
        node.functionExpression.body,
        null);
    return null;
  }

  @override
  DecoratedType visitFunctionExpression(FunctionExpression node) {
    _handleExecutableDeclaration(node, node.declaredElement, null, null,
        node.typeParameters, node.parameters, null, node.body, null);
    return null;
  }

  @override
  DecoratedType visitFunctionTypeAlias(FunctionTypeAlias node) {
    node.metadata.accept(this);
    var declaredElement = node.declaredElement;
    var functionType = declaredElement.function.type;
    var returnType = node.returnType;
    DecoratedType decoratedReturnType;
    var target = NullabilityNodeTarget.element(declaredElement);
    if (returnType != null) {
      _pushNullabilityNodeTarget(target.returnType(), () {
        decoratedReturnType = returnType.accept(this);
      });
    } else {
      // Inferred return type.
      decoratedReturnType = DecoratedType.forImplicitType(
          _typeProvider, functionType.returnType, _graph, target.returnType());
      instrumentation?.implicitReturnType(source, node, decoratedReturnType);
    }
    var previousPositionalParameters = _positionalParameters;
    var previousNamedParameters = _namedParameters;
    _positionalParameters = [];
    _namedParameters = {};
    DecoratedType decoratedFunctionType;
    try {
      node.typeParameters?.accept(this);
      node.parameters?.accept(this);
      // Note: we don't pass _typeFormalBounds into DecoratedType because we're
      // not defining a generic function type, we're defining a generic typedef
      // of an ordinary (non-generic) function type.
      decoratedFunctionType = DecoratedType(functionType, _graph.never,
          returnType: decoratedReturnType,
          positionalParameters: _positionalParameters,
          namedParameters: _namedParameters);
    } finally {
      _positionalParameters = previousPositionalParameters;
      _namedParameters = previousNamedParameters;
    }
    _variables.recordDecoratedElementType(
        declaredElement.function, decoratedFunctionType);
    return null;
  }

  @override
  DecoratedType visitFunctionTypedFormalParameter(
      FunctionTypedFormalParameter node) {
    return _handleFormalParameter(
        node, node.returnType, node.typeParameters, node.parameters);
  }

  @override
  DecoratedType visitGenericTypeAlias(GenericTypeAlias node) {
    node.metadata.accept(this);
    DecoratedType decoratedFunctionType;
    node.typeParameters?.accept(this);
    var target = NullabilityNodeTarget.element(node.declaredElement);
    var returnType = node.functionType.returnType;
    if (returnType != null) {
      _pushNullabilityNodeTarget(target.returnType(), () {
        decoratedFunctionType = node.functionType.accept(this);
      });
    } else {
      decoratedFunctionType = node.functionType.accept(this);
    }
    _variables.recordDecoratedElementType(
        (node.declaredElement as GenericTypeAliasElement).function,
        decoratedFunctionType);
    return null;
  }

  @override
  DecoratedType visitMethodDeclaration(MethodDeclaration node) {
    _handleExecutableDeclaration(
        node,
        node.declaredElement,
        node.metadata,
        node.returnType,
        node.typeParameters,
        node.parameters,
        null,
        node.body,
        null);
    return null;
  }

  @override
  visitMixinDeclaration(MixinDeclaration node) {
    node.metadata.accept(this);
    node.name?.accept(this);
    node.typeParameters?.accept(this);
    node.members.accept(this);
    _handleSupertypeClauses(node, node.declaredElement, null, null,
        node.implementsClause, node.onClause);
    return null;
  }

  @override
  DecoratedType visitSimpleFormalParameter(SimpleFormalParameter node) {
    return _handleFormalParameter(node, node.type, null, null);
  }

  @override
  DecoratedType visitTypeAnnotation(TypeAnnotation node) {
    assert(node != null); // TODO(paulberry)
    var type = node.type;
    var target = (_target ?? NullabilityNodeTarget.text('explicit type'))
        .withCodeRef(node);
    if (type.isVoid || type.isDynamic) {
      var nullabilityNode = NullabilityNode.forTypeAnnotation(target);
      var decoratedType = DecoratedType(type, nullabilityNode);
      _variables.recordDecoratedTypeAnnotation(
          source, node, decoratedType, null);
      return decoratedType;
    }
    var typeArguments = const <DecoratedType>[];
    DecoratedType decoratedReturnType;
    var positionalParameters = const <DecoratedType>[];
    var namedParameters = const <String, DecoratedType>{};
    if (type is InterfaceType && type.element.typeParameters.isNotEmpty) {
      if (node is TypeName) {
        if (node.typeArguments == null) {
          int index = 0;
          typeArguments = type.typeArguments
              .map((t) => DecoratedType.forImplicitType(
                  _typeProvider, t, _graph, target.typeArgument(index++)))
              .toList();
          instrumentation?.implicitTypeArguments(source, node, typeArguments);
        } else {
          typeArguments =
              node.typeArguments.arguments.map((t) => t.accept(this)).toList();
        }
      } else {
        assert(false); // TODO(paulberry): is this possible?
      }
    }
    if (node is GenericFunctionType) {
      var returnType = node.returnType;
      if (returnType == null) {
        decoratedReturnType = DecoratedType.forImplicitType(_typeProvider,
            DynamicTypeImpl.instance, _graph, target.returnType());
        instrumentation?.implicitReturnType(source, node, decoratedReturnType);
      } else {
        // If [_target] is non-null, then it represents the return type for
        // a FunctionTypeAlias. Otherwise, create a return type target for
        // `target`.
        _pushNullabilityNodeTarget(_target ?? target.returnType(), () {
          decoratedReturnType = returnType.accept(this);
        });
      }
      positionalParameters = <DecoratedType>[];
      namedParameters = <String, DecoratedType>{};
      var previousPositionalParameters = _positionalParameters;
      var previousNamedParameters = _namedParameters;
      try {
        _positionalParameters = positionalParameters;
        _namedParameters = namedParameters;
        node.typeParameters?.accept(this);
        node.parameters.accept(this);
      } finally {
        _positionalParameters = previousPositionalParameters;
        _namedParameters = previousNamedParameters;
      }
    }
    NullabilityNode nullabilityNode;
    if (typeIsNonNullableByContext(node)) {
      nullabilityNode = _graph.never;
    } else {
      nullabilityNode = NullabilityNode.forTypeAnnotation(target);
    }
    DecoratedType decoratedType;
    if (type is FunctionType && node is! GenericFunctionType) {
      (node as TypeName).typeArguments?.accept(this);
      // node is a reference to a typedef.  Treat it like an inferred type (we
      // synthesize new nodes for it).  These nodes will be unioned with the
      // typedef nodes by the edge builder.
      decoratedType = DecoratedType.forImplicitFunction(
          _typeProvider, type, nullabilityNode, _graph, target);
    } else {
      decoratedType = DecoratedType(type, nullabilityNode,
          typeArguments: typeArguments,
          returnType: decoratedReturnType,
          positionalParameters: positionalParameters,
          namedParameters: namedParameters);
    }
    _variables.recordDecoratedTypeAnnotation(
        source,
        node,
        decoratedType,
        PotentiallyAddQuestionSuffix(
            nullabilityNode, decoratedType.type, node.end));
    switch (getPostfixHint(node.endToken)) {
      case NullabilityComment.bang:
        _graph.makeNonNullableUnion(
            decoratedType.node, NullabilityCommentOrigin(source, node, false));
        break;
      case NullabilityComment.question:
        _graph.makeNullableUnion(
            decoratedType.node, NullabilityCommentOrigin(source, node, true));
        break;
      case NullabilityComment.none:
        break;
    }
    return decoratedType;
  }

  @override
  DecoratedType visitTypeName(TypeName node) {
    typeNameVisited(node); // Note this has been visited to TypeNameTracker.
    return visitTypeAnnotation(node);
  }

  @override
  DecoratedType visitTypeParameter(TypeParameter node) {
    var element = node.declaredElement;
    var bound = node.bound;
    DecoratedType decoratedBound;
    if (bound != null) {
      decoratedBound = bound.accept(this);
    } else {
      var nullabilityNode = NullabilityNode.forInferredType(
          NullabilityNodeTarget.typeParameterBound(element));
      decoratedBound = DecoratedType(_typeProvider.objectType, nullabilityNode);
      _graph.connect(_graph.always, nullabilityNode,
          AlwaysNullableTypeOrigin.forElement(element, false));
    }
    DecoratedTypeParameterBounds.current.put(element, decoratedBound);
    return null;
  }

  @override
  DecoratedType visitVariableDeclarationList(VariableDeclarationList node) {
    node.metadata.accept(this);
    var typeAnnotation = node.type;
    var type = typeAnnotation?.accept(this);
    switch (getPrefixHint(node.firstTokenAfterCommentAndMetadata)) {
      case PrefixHintComment.late_:
        _variables.recordLateHint(source, node);
        break;
      case PrefixHintComment.none:
        break;
    }
    for (var variable in node.variables) {
      variable.metadata.accept(this);
      var declaredElement = variable.declaredElement;
      if (type == null) {
        var target = NullabilityNodeTarget.element(declaredElement);
        type = DecoratedType.forImplicitType(
            _typeProvider, declaredElement.type, _graph, target);
        instrumentation?.implicitType(source, node, type);
      }
      _variables.recordDecoratedElementType(declaredElement, type);
      variable.initializer?.accept(this);
    }
    return null;
  }

  DecoratedType _createDecoratedTypeForClass(
      ClassElement classElement, AstNode node) {
    var typeArguments = classElement.typeParameters
        .map((t) => t.instantiate(nullabilitySuffix: NullabilitySuffix.star))
        .toList();
    var decoratedTypeArguments =
        typeArguments.map((t) => DecoratedType(t, _graph.never)).toList();
    return DecoratedType(
      classElement.instantiate(
        typeArguments: typeArguments,
        nullabilitySuffix: NullabilitySuffix.star,
      ),
      _graph.never,
      typeArguments: decoratedTypeArguments,
    );
  }

  /// Common handling of function and method declarations.
  void _handleExecutableDeclaration(
      AstNode node,
      ExecutableElement declaredElement,
      NodeList<Annotation> metadata,
      TypeAnnotation returnType,
      TypeParameterList typeParameters,
      FormalParameterList parameters,
      NodeList<ConstructorInitializer> initializers,
      FunctionBody body,
      ConstructorName redirectedConstructor) {
    metadata?.accept(this);
    var functionType = declaredElement.type;
    DecoratedType decoratedReturnType;
    var target = NullabilityNodeTarget.element(declaredElement);
    if (returnType != null) {
      _pushNullabilityNodeTarget(target.returnType(), () {
        decoratedReturnType = returnType.accept(this);
      });
    } else if (declaredElement is ConstructorElement) {
      // Constructors have no explicit return type annotation, so use the
      // implicit return type.
      decoratedReturnType = _createDecoratedTypeForClass(
          declaredElement.enclosingElement, parameters.parent);
      instrumentation?.implicitReturnType(source, node, decoratedReturnType);
    } else {
      // Inferred return type.
      decoratedReturnType = DecoratedType.forImplicitType(
          _typeProvider, functionType.returnType, _graph, target);
      instrumentation?.implicitReturnType(source, node, decoratedReturnType);
    }
    var previousPositionalParameters = _positionalParameters;
    var previousNamedParameters = _namedParameters;
    _positionalParameters = [];
    _namedParameters = {};
    DecoratedType decoratedFunctionType;
    try {
      typeParameters?.accept(this);
      _pushNullabilityNodeTarget(target, () => parameters?.accept(this));
      redirectedConstructor?.accept(this);
      initializers?.accept(this);
      decoratedFunctionType = DecoratedType(functionType, _graph.never,
          returnType: decoratedReturnType,
          positionalParameters: _positionalParameters,
          namedParameters: _namedParameters);
      body?.accept(this);
    } finally {
      _positionalParameters = previousPositionalParameters;
      _namedParameters = previousNamedParameters;
    }
    _variables.recordDecoratedElementType(
        declaredElement, decoratedFunctionType);
  }

  DecoratedType _handleFormalParameter(
      FormalParameter node,
      TypeAnnotation type,
      TypeParameterList typeParameters,
      FormalParameterList parameters) {
    var declaredElement = node.declaredElement;
    node.metadata?.accept(this);
    DecoratedType decoratedType;
    var target = NullabilityNodeTarget.element(declaredElement);
    if (parameters == null) {
      if (type != null) {
        decoratedType = type.accept(this);
      } else {
        decoratedType = DecoratedType.forImplicitType(
            _typeProvider, declaredElement.type, _graph, target);
        instrumentation?.implicitType(source, node, decoratedType);
      }
    } else {
      DecoratedType decoratedReturnType;
      if (type == null) {
        decoratedReturnType = DecoratedType.forImplicitType(_typeProvider,
            DynamicTypeImpl.instance, _graph, target.returnType());
        instrumentation?.implicitReturnType(source, node, decoratedReturnType);
      } else {
        decoratedReturnType = type.accept(this);
      }
      if (typeParameters != null) {
        // TODO(paulberry)
        _unimplemented(
            typeParameters, 'Function-typed parameter with type parameters');
      }
      var positionalParameters = <DecoratedType>[];
      var namedParameters = <String, DecoratedType>{};
      var previousPositionalParameters = _positionalParameters;
      var previousNamedParameters = _namedParameters;
      try {
        _positionalParameters = positionalParameters;
        _namedParameters = namedParameters;
        parameters.accept(this);
      } finally {
        _positionalParameters = previousPositionalParameters;
        _namedParameters = previousNamedParameters;
      }
      decoratedType = DecoratedType(
          declaredElement.type, NullabilityNode.forTypeAnnotation(target),
          returnType: decoratedReturnType,
          positionalParameters: positionalParameters,
          namedParameters: namedParameters);
    }
    _variables.recordDecoratedElementType(declaredElement, decoratedType);
    if (declaredElement.isNamed) {
      _namedParameters[declaredElement.name] = decoratedType;
    } else {
      _positionalParameters.add(decoratedType);
    }
    return decoratedType;
  }

  void _handleSupertypeClauses(
      NamedCompilationUnitMember astNode,
      ClassElement declaredElement,
      TypeName superclass,
      WithClause withClause,
      ImplementsClause implementsClause,
      OnClause onClause) {
    var supertypes = <TypeName>[];
    supertypes.add(superclass);
    if (withClause != null) {
      supertypes.addAll(withClause.mixinTypes);
    }
    if (implementsClause != null) {
      supertypes.addAll(implementsClause.interfaces);
    }
    if (onClause != null) {
      supertypes.addAll(onClause.superclassConstraints);
    }
    var decoratedSupertypes = <ClassElement, DecoratedType>{};
    for (var supertype in supertypes) {
      DecoratedType decoratedSupertype;
      if (supertype == null) {
        var target = NullabilityNodeTarget.text('implicit object supertype')
            .withCodeRef(astNode);
        var nullabilityNode = NullabilityNode.forInferredType(target);
        _graph.makeNonNullableUnion(
            nullabilityNode, NonNullableObjectSuperclass(source, astNode));
        decoratedSupertype =
            DecoratedType(_typeProvider.objectType, nullabilityNode);
      } else {
        decoratedSupertype = supertype.accept(this);
      }
      var class_ = (decoratedSupertype.type as InterfaceType).element;
      decoratedSupertypes[class_] = decoratedSupertype;
    }
    _variables.recordDecoratedDirectSupertypes(
        declaredElement, decoratedSupertypes);
  }

  void _pushNullabilityNodeTarget(NullabilityNodeTarget target, Function() fn) {
    NullabilityNodeTarget previousTarget = _target;
    try {
      _target = target;
      fn();
    } finally {
      _target = previousTarget;
    }
  }

  @alwaysThrows
  void _unimplemented(AstNode node, String message) {
    CompilationUnit unit = node.root as CompilationUnit;
    StringBuffer buffer = StringBuffer();
    buffer.write(message);
    buffer.write(' in "');
    buffer.write(node.toSource());
    buffer.write('" on line ');
    buffer.write(unit.lineInfo.getLocation(node.offset).lineNumber);
    buffer.write(' of "');
    buffer.write(unit.declaredElement.source.fullName);
    buffer.write('"');
    throw UnimplementedError(buffer.toString());
  }
}
