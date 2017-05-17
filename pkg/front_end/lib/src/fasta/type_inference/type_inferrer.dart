// Copyright (c) 2017, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

import 'package:front_end/src/base/instrumentation.dart';
import 'package:front_end/src/fasta/kernel/kernel_shadow_ast.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_engine.dart';
import 'package:front_end/src/fasta/type_inference/type_inference_listener.dart';
import 'package:front_end/src/fasta/type_inference/type_promotion.dart';
import 'package:front_end/src/fasta/type_inference/type_schema.dart';
import 'package:front_end/src/fasta/type_inference/type_schema_elimination.dart';
import 'package:front_end/src/fasta/type_inference/type_schema_environment.dart';
import 'package:kernel/ast.dart'
    show
        BottomType,
        Class,
        Constructor,
        DartType,
        DynamicType,
        Expression,
        Field,
        FunctionNode,
        FunctionType,
        InterfaceType,
        Member,
        Name,
        Procedure,
        ReturnStatement,
        Statement,
        TypeParameter,
        TypeParameterType,
        VariableDeclaration,
        VoidType;
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';

/// Keeps track of the local state for the type inference that occurs during
/// compilation of a single method body or top level initializer.
///
/// This class describes the interface for use by clients of type inference
/// (e.g. BodyBuilder).  Derived classes should derive from [TypeInferrerImpl].
abstract class TypeInferrer {
  /// Gets the [TypePromoter] that can be used to perform type promotion within
  /// this method body or initializer.
  TypePromoter<Expression, VariableDeclaration> get typePromoter;

  /// The URI of the code for which type inference is currently being
  /// performed--this is used for testing.
  String get uri;

  /// Gets the [FieldNode] corresponding to the given [readTarget], if any.
  FieldNode getFieldNodeForReadTarget(Member readTarget);

  /// Performs type inference on the given [statement].
  ///
  /// Derived classes should override this method with logic that dispatches on
  /// the statement type and calls the appropriate specialized "infer" method.
  void inferStatement(Statement statement);
}

/// Derived class containing generic implementations of [TypeInferrer].
///
/// This class contains as much of the implementation of type inference as
/// possible without knowing the identity of the type parameters.  It defers to
/// abstract methods for everything else.
abstract class TypeInferrerImpl extends TypeInferrer {
  static final FunctionType _functionReturningDynamic =
      new FunctionType(const [], const DynamicType());

  @override
  final String uri;

  /// Indicates whether the construct we are currently performing inference for
  /// is outside of a method body, and hence top level type inference rules
  /// should apply.
  final bool isTopLevel = false;

  final CoreTypes coreTypes;

  final bool strongMode;

  final ClassHierarchy classHierarchy;

  final Instrumentation instrumentation;

  final TypeSchemaEnvironment typeSchemaEnvironment;

  final TypeInferenceListener listener;

  /// Context information for the current closure, or `null` if we are not
  /// inside a closure.
  _ClosureContext _closureContext;

  TypeInferrerImpl(TypeInferenceEngineImpl engine, this.uri, this.listener)
      : coreTypes = engine.coreTypes,
        strongMode = engine.strongMode,
        classHierarchy = engine.classHierarchy,
        instrumentation = engine.instrumentation,
        typeSchemaEnvironment = engine.typeSchemaEnvironment;

  /// Gets the type promoter that should be used to promote types during
  /// inference.
  TypePromoter<Expression, VariableDeclaration> get typePromoter;

  /// Gets the initializer for the given [field], or `null` if there is no
  /// initializer.
  Expression getFieldInitializer(KernelField field);

  /// Performs the core type inference algorithm for type cast expressions.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferAsExpression(DartType typeContext, bool typeNeeded,
      Expression operand, DartType type) {
    typeNeeded = listener.asExpressionEnter(typeContext) || typeNeeded;
    inferExpression(operand, null, false);
    var inferredType = typeNeeded ? type : null;
    listener.asExpressionExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for boolean literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferBoolLiteral(DartType typeContext, bool typeNeeded) {
    typeNeeded = listener.boolLiteralEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? coreTypes.boolClass.rawType : null;
    listener.boolLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for conditional expressions.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [condition], [then], and [otherwise] are the subexpressions.  The inferred
  /// type is reported via [setStaticType].
  DartType inferConditionalExpression(
      DartType typeContext,
      bool typeNeeded,
      Expression condition,
      Expression then,
      Expression otherwise,
      void setStaticType(DartType type)) {
    typeNeeded = listener.conditionalExpressionEnter(typeContext) || typeNeeded;
    inferExpression(condition, coreTypes.boolClass.rawType, false);
    // TODO(paulberry): is it correct to pass the context down?
    DartType thenType = inferExpression(then, typeContext, true);
    DartType otherwiseType = inferExpression(otherwise, typeContext, true);
    // TODO(paulberry): the spec proposal says we should only use LUB if the
    // typeContext is `null`.  If typeContext is non-null, we should use the
    // greatest closure of the context with respect to `?`
    DartType type =
        typeSchemaEnvironment.getLeastUpperBound(thenType, otherwiseType);
    setStaticType(type);
    var inferredType = typeNeeded ? type : null;
    listener.conditionalExpressionExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for constructor invocations.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [offset] is the location of the constructor invocation in the source file.
  /// [target] is the constructor that is being called.  [explicitTypeArguments]
  /// is the set of type arguments explicitly provided, or `null` if no type
  /// arguments were provided.  [forEachArgument] is a callback which can be
  /// used to iterate through all constructor arguments (both named and
  /// positional).  [setInferredTypeArguments] is a callback which can be used
  /// to record the inferred type arguments.
  DartType inferConstructorInvocation(
      DartType typeContext,
      bool typeNeeded,
      int offset,
      Constructor target,
      List<DartType> explicitTypeArguments,
      void forEachArgument(void callback(String name, Expression expression)),
      void setInferredTypeArguments(List<DartType> types)) {
    typeNeeded = listener.constructorInvocationEnter(typeContext) || typeNeeded;
    var inferredType = _inferInvocation(
        typeContext,
        typeNeeded,
        offset,
        target.function.functionType,
        target.enclosingClass.thisType,
        explicitTypeArguments,
        forEachArgument,
        setInferredTypeArguments);
    listener.constructorInvocationExit(inferredType);
    return inferredType;
  }

  /// Modifies a type as appropriate when inferring a declared variable's type.
  DartType inferDeclarationType(DartType initializerType) {
    if (initializerType is BottomType ||
        (initializerType is InterfaceType &&
            initializerType.classNode == coreTypes.nullClass)) {
      // If the initializer type is Null or bottom, the inferred type is
      // dynamic.
      // TODO(paulberry): this rule is inherited from analyzer behavior but is
      // not spec'ed anywhere.
      return const DynamicType();
    }
    return initializerType;
  }

  /// Performs the core type inference algorithm for double literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferDoubleLiteral(DartType typeContext, bool typeNeeded) {
    typeNeeded = listener.doubleLiteralEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? coreTypes.doubleClass.rawType : null;
    listener.doubleLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs type inference on the given [expression].
  ///
  /// [typeContext] is the expected type of the expression, based on surrounding
  /// code.  [typeNeeded] indicates whether it is necessary to compute the
  /// actual type of the expression.  If [typeNeeded] is `true`, the actual type
  /// of the expression is returned; otherwise `null` is returned.
  ///
  /// Derived classes should override this method with logic that dispatches on
  /// the expression type and calls the appropriate specialized "infer" method.
  DartType inferExpression(
      Expression expression, DartType typeContext, bool typeNeeded);

  /// Performs the core type inference algorithm for expression statements.
  void inferExpressionStatement(Expression expression) {
    inferExpression(expression, null, false);
  }

  /// Performs type inference on the given [field]'s initializer expression.
  ///
  /// Derived classes should provide an implementation that calls
  /// [inferExpression] for the given [field]'s initializer expression.
  DartType inferFieldInitializer(
      KernelField field, DartType type, bool typeNeeded);

  /// Performs the core type inference algorithm for local function
  /// declarations.
  ///
  /// [body] is the body of the function.
  void inferFunctionDeclaration(Statement body) {
    var oldClosureContext = _closureContext;
    _closureContext = null;
    inferStatement(body);
    _closureContext = oldClosureContext;
  }

  /// Performs the core type inference algorithm for function expressions.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [body] is the body of the expression.  [isExpressionFunction] indicates
  /// whether the function expression was declared using "=>" syntax.  [isAsync]
  /// and [isGenerator] together indicate whether the function is marked as
  /// "async", "async*", or "sync*".  [offset] is the character offset of the
  /// function expression.
  ///
  /// [setReturnType] is a callback that will be used to store the return type
  /// of the function expression.  [getFunctionType] is a callback that will be
  /// used to query the function expression for its full expression type.
  DartType inferFunctionExpression(
      DartType typeContext,
      bool typeNeeded,
      FunctionNode function,
      bool isAsync,
      bool isGenerator,
      int offset,
      void setReturnType(DartType type),
      DartType getFunctionType()) {
    typeNeeded = listener.functionExpressionEnter(typeContext) || typeNeeded;
    // TODO(paulberry): do we also need to visit default parameter values?

    // Let `<T0, ..., Tn>` be the set of type parameters of the closure (with
    // `n`=0 if there are no type parameters).
    List<TypeParameter> typeParameters = function.typeParameters;

    // Let `(P0 x0, ..., Pm xm)` be the set of formal parameters of the closure
    // (including required, positional optional, and named optional parameters).
    // If any type `Pi` is missing, denote it as `_`.
    List<VariableDeclaration> formals = function.positionalParameters.toList()
      ..addAll(function.namedParameters);

    // Let `B` denote the closure body.  If `B` is an expression function body
    // (`=> e`), treat it as equivalent to a block function body containing a
    // single `return` statement (`{ return e; }`).

    // Attempt to match `K` as a function type compatible with the closure (that
    // is, one having n type parameters and a compatible set of formal
    // parameters).  If there is a successful match, let `<S0, ..., Sn>` be the
    // set of matched type parameters and `(Q0, ..., Qm)` be the set of matched
    // formal parameter types, and let `N` be the return type.
    Substitution substitution;
    List<DartType> formalTypesFromContext =
        new List<DartType>.filled(formals.length, null);
    DartType returnContext;
    if (strongMode && typeContext is FunctionType) {
      for (int i = 0; i < formals.length; i++) {
        if (i < function.positionalParameters.length) {
          formalTypesFromContext[i] =
              _getPositionalParameterType(typeContext, i);
        } else {
          formalTypesFromContext[i] =
              _getNamedParameterType(typeContext, formals[i].name);
        }
      }
      returnContext = typeContext.returnType;

      // Let `[T/S]` denote the type substitution where each `Si` is replaced with
      // the corresponding `Ti`.
      var substitutionMap = <TypeParameter, DartType>{};
      for (int i = 0; i < typeContext.typeParameters.length; i++) {
        substitutionMap[typeContext.typeParameters[i]] =
            i < typeParameters.length
                ? new TypeParameterType(typeParameters[i])
                : const DynamicType();
      }
      substitution = Substitution.fromMap(substitutionMap);
    } else {
      // If the match is not successful because  `K` is `_`, let all `Si`, all
      // `Qi`, and `N` all be `_`.

      // If the match is not successful for any other reason, this will result in
      // a type error, so the implementation is free to choose the best error
      // recovery path.
      substitution = Substitution.empty;
    }

    // Define `Ri` as follows: if `Pi` is not `_`, let `Ri` be `Pi`.
    // Otherwise, if `Qi` is not `_`, let `Ri` be the greatest closure of
    // `Qi[T/S]` with respect to `?`.  Otherwise, let `Ri` be `dynamic`.
    for (int i = 0; i < formals.length; i++) {
      KernelVariableDeclaration formal = formals[i];
      if (KernelVariableDeclaration.isImplicitlyTyped(formal)) {
        if (formalTypesFromContext[i] != null) {
          var inferredType = greatestClosure(coreTypes,
              substitution.substituteType(formalTypesFromContext[i]));
          instrumentation?.record(Uri.parse(uri), formal.fileOffset, 'type',
              new InstrumentationValueForType(inferredType));
          formal.type = inferredType;
        }
      }
    }

    // Let `N’` be `N[T/S]`, adjusted accordingly if the closure is declared
    // with `async`, `async*`, or `sync*`.
    if (returnContext != null) {
      returnContext = substitution.substituteType(returnContext);
    }
    if (isGenerator) {
      if (isAsync) {
        returnContext =
            _getTypeArgumentOf(returnContext, coreTypes.streamClass);
      } else {
        returnContext =
            _getTypeArgumentOf(returnContext, coreTypes.iterableClass);
      }
    } else if (isAsync) {
      // TODO(paulberry): do we have to handle FutureOr<> here?
      returnContext = _getTypeArgumentOf(returnContext, coreTypes.futureClass);
    }

    // Apply type inference to `B` in return context `N’`, with any references
    // to `xi` in `B` having type `Pi`.  This produces `B’`.
    bool isExpressionFunction = function.body is ReturnStatement;
    bool needToSetReturnType = isExpressionFunction || strongMode;
    _ClosureContext oldClosureContext = _closureContext;
    _closureContext = new _ClosureContext(isAsync, isGenerator, returnContext);
    inferStatement(function.body);

    // If the closure is declared with `async*` or `sync*`, let `M` be the least
    // upper bound of the types of the `yield` expressions in `B’`, or `void` if
    // `B’` contains no `yield` expressions.  Otherwise, let `M` be the least
    // upper bound of the types of the `return` expressions in `B’`, or `void`
    // if `B’` contains no `return` expressions.
    DartType inferredReturnType;
    if (needToSetReturnType || typeNeeded) {
      inferredReturnType = inferReturnType(
          _closureContext.inferredReturnType, isExpressionFunction);
      if (!isExpressionFunction &&
          returnContext != null &&
          !typeSchemaEnvironment.isSubtypeOf(
              inferredReturnType, returnContext)) {
        // For block-bodied functions, if the inferred return type isn't a
        // subtype of the context, we use the context.  TODO(paulberry): this is
        // inherited from analyzer; it's not part of the spec.  See also
        // dartbug.com/29606.
        inferredReturnType = greatestClosure(coreTypes, returnContext);
      }

      // Let `M’` be `M`, adjusted accordingly if the closure is declared with
      // `async`, `async*`, or `sync*`.
      if (isGenerator) {
        if (isAsync) {
          inferredReturnType =
              _wrapType(inferredReturnType, coreTypes.streamClass);
        } else {
          inferredReturnType =
              _wrapType(inferredReturnType, coreTypes.iterableClass);
        }
      } else if (isAsync) {
        inferredReturnType =
            _wrapType(inferredReturnType, coreTypes.futureClass);
      }
    }

    // Then the result of inference is `<T0, ..., Tn>(R0 x0, ..., Rn xn) B` with
    // type `<T0, ..., Tn>(R0, ..., Rn) -> M’` (with some of the `Ri` and `xi`
    // denoted as optional or named parameters, if appropriate).
    if (needToSetReturnType) {
      instrumentation?.record(Uri.parse(uri), offset, 'returnType',
          new InstrumentationValueForType(inferredReturnType));
      setReturnType(inferredReturnType);
    }
    _closureContext = oldClosureContext;
    var inferredType = typeNeeded ? getFunctionType() : null;
    listener.functionExpressionExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for if statements.
  void inferIfStatement(
      Expression condition, Statement then, Statement otherwise) {
    inferExpression(condition, coreTypes.boolClass.rawType, false);
    inferStatement(then);
    if (otherwise != null) inferStatement(otherwise);
  }

  /// Performs the core type inference algorithm for integer literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferIntLiteral(DartType typeContext, bool typeNeeded) {
    typeNeeded = listener.intLiteralEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? coreTypes.intClass.rawType : null;
    listener.intLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for an "is" expression.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [operand] is the expression appearing to the left of "is".
  DartType inferIsExpression(
      DartType typeContext, bool typeNeeded, Expression operand) {
    typeNeeded = listener.isExpressionEnter(typeContext) || typeNeeded;
    inferExpression(operand, null, false);
    var inferredType = typeNeeded ? coreTypes.boolClass.rawType : null;
    listener.isExpressionExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for list literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferListLiteral(
      DartType typeContext,
      bool typeNeeded,
      int offset,
      DartType declaredTypeArgument,
      Iterable<Expression> expressions,
      void setTypeArgument(DartType typeArgument)) {
    typeNeeded = listener.listLiteralEnter(typeContext) || typeNeeded;
    var listClass = coreTypes.listClass;
    var listType = listClass.thisType;
    List<DartType> inferredTypes;
    DartType inferredTypeArgument;
    List<DartType> formalTypes;
    List<DartType> actualTypes;
    bool inferenceNeeded = declaredTypeArgument == null && strongMode;
    if (inferenceNeeded) {
      inferredTypes = [const UnknownType()];
      typeSchemaEnvironment.inferGenericFunctionOrType(listType,
          listClass.typeParameters, null, null, typeContext, inferredTypes);
      inferredTypeArgument = inferredTypes[0];
      formalTypes = [];
      actualTypes = [];
    } else {
      inferredTypeArgument = declaredTypeArgument ?? const DynamicType();
    }
    for (var expression in expressions) {
      var expressionType =
          inferExpression(expression, inferredTypeArgument, inferenceNeeded);
      if (inferenceNeeded) {
        formalTypes.add(listType.typeArguments[0]);
        actualTypes.add(expressionType);
      }
    }
    if (inferenceNeeded) {
      typeSchemaEnvironment.inferGenericFunctionOrType(
          listType,
          listClass.typeParameters,
          formalTypes,
          actualTypes,
          typeContext,
          inferredTypes);
      inferredTypeArgument = inferredTypes[0];
      instrumentation?.record(Uri.parse(uri), offset, 'typeArgs',
          new InstrumentationValueForTypeArgs([inferredTypeArgument]));
      setTypeArgument(inferredTypeArgument);
    }
    var inferredType = typeNeeded
        ? new InterfaceType(listClass, [inferredTypeArgument])
        : null;
    listener.listLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for method invocations.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [offset] is the location of the method invocation in the source file.
  /// [receiver] is the object whose method is being invoked, and [methodName]
  /// is the name of the method.  [explicitTypeArguments] is the set of type
  /// arguments explicitly provided, or `null` if no type arguments were
  /// provided.  [forEachArgument] is a callback which can be used to iterate
  /// through all invocation arguments (both named and positional).
  /// [setInferredTypeArguments] is a callback which can be used to record the
  /// inferred type arguments.  [setInterfaceTarget] is a callback which can be
  /// used to record the method being invoked.
  DartType inferMethodInvocation(
      DartType typeContext,
      bool typeNeeded,
      int offset,
      Expression receiver,
      Name methodName,
      List<DartType> explicitTypeArguments,
      void forEachArgument(void callback(String name, Expression expression)),
      void setInferredTypeArguments(List<DartType> types),
      void setInterfaceTarget(Procedure procedure)) {
    typeNeeded = listener.methodInvocationEnter(typeContext) || typeNeeded;
    // First infer the receiver so we can look up the method that was invoked.
    var receiverType = inferExpression(receiver, null, true);
    bool isOverloadedArithmeticOperator = false;
    Member interfaceMember;
    if (receiverType is InterfaceType) {
      interfaceMember =
          classHierarchy.getInterfaceMember(receiverType.classNode, methodName);
      if (interfaceMember is Procedure) {
        setInterfaceTarget(interfaceMember);
        isOverloadedArithmeticOperator = typeSchemaEnvironment
            .isOverloadedArithmeticOperator(interfaceMember);
      }
    }
    var calleeType = _getCalleeFunctionType(
        interfaceMember, receiverType, methodName, offset);
    var inferredType = _inferInvocation(
        typeContext,
        typeNeeded,
        offset,
        calleeType,
        calleeType.returnType,
        explicitTypeArguments,
        forEachArgument,
        setInferredTypeArguments,
        isOverloadedArithmeticOperator: isOverloadedArithmeticOperator,
        receiverType: receiverType);
    listener.methodInvocationExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for null literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferNullLiteral(DartType typeContext, bool typeNeeded) {
    typeNeeded = listener.nullLiteralEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? coreTypes.nullClass.rawType : null;
    listener.nullLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for return statements.
  ///
  /// [body] is the expression being returned, or `null` for a bare return
  /// statement.
  void inferReturnStatement(Expression expression) {
    var closureContext = _closureContext;
    var typeContext = closureContext != null && !closureContext.isGenerator
        ? closureContext.returnContext
        : null;
    var inferredType = expression != null
        ? inferExpression(expression, typeContext, closureContext != null)
        : const VoidType();
    if (expression == null) {
      // Analyzer treats bare `return` statements as having no effect on the
      // inferred type of the closure.  TODO(paulberry): is this what we want
      // for Fasta?
      return;
    }
    closureContext?.updateInferredReturnType(this, inferredType);
  }

  /// Modifies a type as appropriate when inferring a closure return type.
  DartType inferReturnType(DartType returnType, bool isExpressionFunction) {
    if (returnType == null) {
      // Analyzer infers `Null` if there is no `return` expression; the spec
      // says to return `void`.  TODO(paulberry): resolve this difference.
      return coreTypes.nullClass.rawType;
    }
    if (isExpressionFunction &&
        returnType is InterfaceType &&
        identical(returnType.classNode, coreTypes.nullClass)) {
      // Analyzer coerces `Null` to `dynamic` in expression functions; the spec
      // doesn't say to do this.  TODO(paulberry): resolve this difference.
      return const DynamicType();
    }
    return returnType;
  }

  /// Performs the core type inference algorithm for static variable getters.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [getterType] is the type of the field being referenced, or the return type
  /// of the getter.
  DartType inferStaticGet(
      DartType typeContext, bool typeNeeded, DartType getterType) {
    typeNeeded = listener.staticGetEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? getterType : null;
    listener.staticGetExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for method invocations.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  ///
  /// [offset] is the location of the method invocation in the source file.
  /// [receiver] is the object whose method is being invoked, and [methodName]
  /// is the name of the method.  [explicitTypeArguments] is the set of type
  /// arguments explicitly provided, or `null` if no type arguments were
  /// provided.  [forEachArgument] is a callback which can be used to iterate
  /// through all invocation arguments (both named and positional).
  /// [setInferredTypeArguments] is a callback which can be used to record the
  /// inferred type arguments.  [setInterfaceTarget] is a callback which can be
  /// used to record the method being invoked.
  DartType inferStaticInvocation(
      DartType typeContext,
      bool typeNeeded,
      int offset,
      Procedure target,
      Name methodName,
      List<DartType> explicitTypeArguments,
      void forEachArgument(void callback(String name, Expression expression)),
      void setInferredTypeArguments(List<DartType> types)) {
    typeNeeded = listener.staticInvocationEnter(typeContext) || typeNeeded;
    var calleeType = target.function.functionType;
    var inferredType = _inferInvocation(
        typeContext,
        typeNeeded,
        offset,
        calleeType,
        calleeType.returnType,
        explicitTypeArguments,
        forEachArgument,
        setInferredTypeArguments);
    listener.staticInvocationExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for string concatenations.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferStringConcatenation(
      DartType typeContext, bool typeNeeded, Iterable<Expression> expressions) {
    typeNeeded = listener.stringConcatenationEnter(typeContext) || typeNeeded;
    for (Expression expression in expressions) {
      inferExpression(expression, null, false);
    }
    var inferredType = typeNeeded ? coreTypes.stringClass.rawType : null;
    listener.stringConcatenationExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for string literals.
  ///
  /// [typeContext], [typeNeeded], and the return value behave as described in
  /// [inferExpression].
  DartType inferStringLiteral(DartType typeContext, bool typeNeeded) {
    typeNeeded = listener.stringLiteralEnter(typeContext) || typeNeeded;
    var inferredType = typeNeeded ? coreTypes.stringClass.rawType : null;
    listener.stringLiteralExit(inferredType);
    return inferredType;
  }

  /// Performs the core type inference algorithm for variable declarations.
  ///
  /// [declaredType] is the declared type of the variable, or `null` if the type
  /// should be inferred.  [initializer] is the initializer expression.
  /// [offset] is the character offset of the variable declaration (for
  /// instrumentation).  [setType] is a callback that will be used to set the
  /// inferred type.
  void inferVariableDeclaration(DartType declaredType, Expression initializer,
      int offset, void setType(DartType type)) {
    if (initializer == null) return;
    var inferredType = inferDeclarationType(
        inferExpression(initializer, declaredType, declaredType == null));
    if (strongMode && declaredType == null) {
      instrumentation?.record(Uri.parse(uri), offset, 'type',
          new InstrumentationValueForType(inferredType));
      setType(inferredType);
    }
  }

  DartType inferVariableGet(
      DartType typeContext,
      bool typeNeeded,
      bool mutatedInClosure,
      TypePromotionFact<VariableDeclaration> typePromotionFact,
      TypePromotionScope typePromotionScope,
      int offset,
      DartType declaredOrInferredType,
      void setPromotedType(DartType type)) {
    typeNeeded = listener.variableGetEnter(typeContext) || typeNeeded;
    DartType promotedType = typePromoter.computePromotedType(
        typePromotionFact, typePromotionScope, mutatedInClosure);
    if (promotedType != null) {
      instrumentation?.record(Uri.parse(uri), offset, 'promotedType',
          new InstrumentationValueForType(promotedType));
    }
    setPromotedType(promotedType);
    var inferredType =
        typeNeeded ? (promotedType ?? declaredOrInferredType) : null;
    listener.variableGetExit(inferredType);
    return inferredType;
  }

  DartType inferVariableSet(DartType typeContext, bool typeNeeded,
      DartType declaredType, Expression value) {
    typeNeeded = listener.variableSetEnter(typeContext) || typeNeeded;
    var inferredType = inferExpression(value, declaredType, typeNeeded);
    listener.variableSetExit(inferredType);
    return inferredType;
  }

  FunctionType _getCalleeFunctionType(Member interfaceMember,
      DartType receiverType, Name methodName, int offset) {
    if (receiverType is InterfaceType) {
      if (interfaceMember == null) return _functionReturningDynamic;
      var memberClass = interfaceMember.enclosingClass;
      if (interfaceMember is Procedure) {
        instrumentation?.record(Uri.parse(uri), offset, 'target',
            new InstrumentationValueForProcedure(interfaceMember));
        var memberFunctionType = interfaceMember.function.functionType;
        if (memberClass.typeParameters.isNotEmpty) {
          var castedType = classHierarchy.getClassAsInstanceOf(
              receiverType.classNode, memberClass);
          memberFunctionType = Substitution
              .fromInterfaceType(Substitution
                  .fromInterfaceType(receiverType)
                  .substituteType(castedType.asInterfaceType))
              .substituteType(memberFunctionType);
        }
        return memberFunctionType;
      } else if (interfaceMember is Field) {
        // TODO(paulberry): handle this case
        return _functionReturningDynamic;
      } else {
        return _functionReturningDynamic;
      }
    } else if (receiverType is DynamicType) {
      return _functionReturningDynamic;
    } else if (receiverType is FunctionType) {
      // TODO(paulberry): handle the case of invoking .call() or .toString() on
      // a function type.
      return _functionReturningDynamic;
    } else if (receiverType is TypeParameterType) {
      // TODO(paulberry): use the bound
      return _functionReturningDynamic;
    } else {
      // TODO(paulberry): handle the case of invoking .toString() on a type
      // that's none of the above (e.g. `dynamic` or `bottom`)
      return _functionReturningDynamic;
    }
  }

  DartType _getNamedParameterType(FunctionType functionType, String name) {
    return functionType.getNamedParameter(name) ?? const DynamicType();
  }

  DartType _getPositionalParameterType(FunctionType functionType, int i) {
    if (i < functionType.positionalParameters.length) {
      return functionType.positionalParameters[i];
    } else {
      return const DynamicType();
    }
  }

  DartType _getTypeArgumentOf(DartType type, Class class_) {
    if (type is InterfaceType && identical(type.classNode, class_)) {
      return type.typeArguments[0];
    } else {
      return null;
    }
  }

  /// Performs the type inference steps that are shared by all kinds of
  /// invocations (constructors, instance methods, and static methods).
  DartType _inferInvocation(
      DartType typeContext,
      bool typeNeeded,
      int offset,
      FunctionType calleeType,
      DartType returnType,
      List<DartType> explicitTypeArguments,
      void forEachArgument(void callback(String name, Expression expression)),
      void setInferredTypeArguments(List<DartType> types),
      {bool isOverloadedArithmeticOperator: false,
      DartType receiverType}) {
    var calleeTypeParameters = calleeType.typeParameters;
    bool inferenceNeeded = explicitTypeArguments == null &&
        strongMode &&
        calleeTypeParameters.isNotEmpty;
    List<DartType> inferredTypes;
    Substitution substitution;
    List<DartType> formalTypes;
    List<DartType> actualTypes;
    if (inferenceNeeded) {
      inferredTypes = new List<DartType>.filled(
          calleeTypeParameters.length, const UnknownType());
      typeSchemaEnvironment.inferGenericFunctionOrType(returnType,
          calleeTypeParameters, null, null, typeContext, inferredTypes);
      substitution =
          Substitution.fromPairs(calleeTypeParameters, inferredTypes);
      formalTypes = [];
      actualTypes = [];
    } else if (explicitTypeArguments != null &&
        calleeTypeParameters.length == explicitTypeArguments.length) {
      substitution =
          Substitution.fromPairs(calleeTypeParameters, explicitTypeArguments);
    } else if (calleeTypeParameters.length != 0) {
      substitution = Substitution.fromPairs(
          calleeTypeParameters,
          new List<DartType>.filled(
              calleeTypeParameters.length, const DynamicType()));
    }
    int i = 0;
    forEachArgument((name, expression) {
      DartType formalType = name != null
          ? _getNamedParameterType(calleeType, name)
          : _getPositionalParameterType(calleeType, i++);
      DartType inferredFormalType = substitution != null
          ? substitution.substituteType(formalType)
          : formalType;
      var expressionType = inferExpression(expression, inferredFormalType,
          inferenceNeeded || isOverloadedArithmeticOperator);
      if (inferenceNeeded) {
        formalTypes.add(formalType);
        actualTypes.add(expressionType);
      }
      if (isOverloadedArithmeticOperator) {
        returnType = typeSchemaEnvironment.getTypeOfOverloadedArithmetic(
            receiverType, expressionType);
      }
    });
    if (inferenceNeeded) {
      typeSchemaEnvironment.inferGenericFunctionOrType(
          returnType,
          calleeTypeParameters,
          formalTypes,
          actualTypes,
          typeContext,
          inferredTypes);
      substitution =
          Substitution.fromPairs(calleeTypeParameters, inferredTypes);
      instrumentation?.record(Uri.parse(uri), offset, 'typeArgs',
          new InstrumentationValueForTypeArgs(inferredTypes));
      setInferredTypeArguments(inferredTypes);
    }
    DartType inferredType;
    if (typeNeeded) {
      inferredType = substitution == null
          ? returnType
          : substitution.substituteType(returnType);
    }
    return inferredType;
  }

  DartType _wrapType(DartType type, Class class_) {
    return new InterfaceType(class_, <DartType>[type]);
  }
}

/// Keeps track of information about the innermost function or closure being
/// inferred.
class _ClosureContext {
  final bool isAsync;

  final bool isGenerator;

  final DartType returnContext;

  DartType _inferredReturnType;

  _ClosureContext(this.isAsync, this.isGenerator, this.returnContext);

  /// Gets the return type that was inferred for the current closure, or `null`
  /// if there were no `return` statements.
  get inferredReturnType {
    return _inferredReturnType;
  }

  /// Updates the inferred return type based on the presence of a return
  /// statement returning the given [type].
  void updateInferredReturnType(TypeInferrerImpl inferrer, DartType type) {
    if (_inferredReturnType == null) {
      _inferredReturnType = type;
    } else {
      _inferredReturnType = inferrer.typeSchemaEnvironment
          .getLeastUpperBound(_inferredReturnType, type);
    }
  }
}
