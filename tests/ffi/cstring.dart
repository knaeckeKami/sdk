// Copyright (c) 2019, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library FfiTest;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:ffi' show Pointer;

/// Sample non-struct Pointer wrapper for dart:ffi library.
class Utf8 extends ffi.Struct<Utf8> {
  @ffi.Int8()
  int char;

  static String fromUtf8(Pointer<Utf8> str) {
    List<int> units = [];
    int len = 0;
    while (true) {
      int char = str.elementAt(len++).load<Utf8>().char;
      if (char == 0) break;
      units.add(char);
    }
    return Utf8Decoder().convert(units);
  }

  static Pointer<Utf8> toUtf8(String s) {
    Pointer<Utf8> result = Pointer<Utf8>.allocate(count: s.length + 1).cast();
    List<int> units = Utf8Encoder().convert(s);
    for (int i = 0; i < s.length; i++) {
      result.elementAt(i).load<Utf8>().char = units[i];
    }
    result.elementAt(s.length).load<Utf8>().char = 0;
    return result;
  }
}
