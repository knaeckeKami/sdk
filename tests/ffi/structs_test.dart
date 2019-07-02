// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//
// Dart test program for testing dart:ffi struct pointers.

library FfiTest;

import 'dart:ffi';

import "package:expect/expect.dart";

import 'coordinate_bare.dart' as bare;
import 'coordinate.dart';

void main() {
  testStructAllocate();
  testStructFromAddress();
  testStructWithNulls();
  testBareStruct();
  testTypeTest();
}

/// allocates each coordinate separately in c memory
void testStructAllocate() {
  Pointer<Coordinate> c1 =
      Coordinate.allocate(10.0, 10.0, nullptr.cast()).addressOf;
  Pointer<Coordinate> c2 = Coordinate.allocate(20.0, 20.0, c1).addressOf;
  Pointer<Coordinate> c3 = Coordinate.allocate(30.0, 30.0, c2).addressOf;
  c1.load<Coordinate>().next = c3;

  Coordinate currentCoordinate = c1.load();
  Expect.equals(10.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(30.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(20.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(10.0, currentCoordinate.x);

  c1.free();
  c2.free();
  c3.free();
}

/// allocates coordinates consecutively in c memory
void testStructFromAddress() {
  Pointer<Coordinate> c1 = Pointer.allocate(count: 3);
  Pointer<Coordinate> c2 = c1.elementAt(1);
  Pointer<Coordinate> c3 = c1.elementAt(2);
  c1.load<Coordinate>().x = 10.0;
  c1.load<Coordinate>().y = 10.0;
  c1.load<Coordinate>().next = c3;
  c2.load<Coordinate>().x = 20.0;
  c2.load<Coordinate>().y = 20.0;
  c2.load<Coordinate>().next = c1;
  c3.load<Coordinate>().x = 30.0;
  c3.load<Coordinate>().y = 30.0;
  c3.load<Coordinate>().next = c2;

  Coordinate currentCoordinate = c1.load();
  Expect.equals(10.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(30.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(20.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(10.0, currentCoordinate.x);

  c1.free();
}

void testStructWithNulls() {
  Pointer<Coordinate> coordinate =
      Coordinate.allocate(10.0, 10.0, nullptr.cast<Coordinate>()).addressOf;
  Expect.equals(coordinate.load<Coordinate>().next, nullptr);
  coordinate.load<Coordinate>().next = coordinate;
  Expect.notEquals(coordinate.load<Coordinate>().next, nullptr);
  coordinate.load<Coordinate>().next = nullptr.cast();
  Expect.equals(coordinate.load<Coordinate>().next, nullptr);
  coordinate.free();
}

void testBareStruct() {
  int structSize = sizeOf<Double>() * 2 + sizeOf<IntPtr>();
  bare.Coordinate c1 = Pointer<Uint8>.allocate(count: structSize * 3)
      .cast<bare.Coordinate>()
      .load();
  bare.Coordinate c2 =
      c1.addressOf.offsetBy(structSize).cast<bare.Coordinate>().load();
  bare.Coordinate c3 =
      c1.addressOf.offsetBy(structSize * 2).cast<bare.Coordinate>().load();
  c1.x = 10.0;
  c1.y = 10.0;
  c1.next = c3.addressOf;
  c2.x = 20.0;
  c2.y = 20.0;
  c2.next = c1.addressOf;
  c3.x = 30.0;
  c3.y = 30.0;
  c3.next = c2.addressOf;

  bare.Coordinate currentCoordinate = c1;
  Expect.equals(10.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(30.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(20.0, currentCoordinate.x);
  currentCoordinate = currentCoordinate.next.load();
  Expect.equals(10.0, currentCoordinate.x);

  c1.addressOf.free();
}

void testTypeTest() {
  Coordinate c = Coordinate.allocate(10, 10, nullptr.cast<Coordinate>());
  Expect.isTrue(c is Struct);
  Expect.isTrue(c is Struct<Coordinate>);
}
