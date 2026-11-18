import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter_test/flutter_test.dart';

const _lib = 'build/vtshim/libvtshim.dylib';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final missing = !File(_lib).existsSync();
  final skip = missing ? '$_lib is missing: run tool/build-vtshim.sh' : false;
  setUpAll(() {
    if (!missing) Vt.open(_lib);
  });

  Vt make(int cols, int rows) {
    final vt = Vt(cols, rows);
    addTearDown(vt.dispose);
    return vt;
  }

  test('writesTextIntoCells', () {
    final vt = make(10, 3);
    vt.write(_b('ab\x1b[1;31mc\x1b[0m日'));
    final s = vt.snapshot();
    expect([s.cols, s.rows, s.lines.length], [10, 3, 3]);
    final row = s.lines[0].cells;
    expect(row.length, 10);
    expect([row[0].text, row[1].text, row[2].text, row[3].text, row[4].text], ['a', 'b', 'c', '日', '']);
    expect(row[0].fg, isNull);
    expect(row[0].bold, isFalse);
    expect(row[2].bold, isTrue);
    expect(row[2].fg, isNotNull);
    expect(row[3].wide, isTrue);
    expect(row[4].spacer, isTrue);
    expect(s.lines[0].text, 'abc日');
    expect([s.cursorX, s.cursorY, s.cursorVisible], [5, 0, true]);
  }, skip: skip);

  test('combinedClusterStaysInOneCell', () {
    final vt = make(10, 2);
    vt.write(_b('éx'));
    final row = vt.snapshot().lines[0].cells;
    expect(row[0].text, 'é');
    expect(row[1].text, 'x');
  }, skip: skip);

  for (final name in ['shell', 'altexit']) {
    test('replayMatchesReference $name', () {
      final vt = make(100, 30);
      vt.write(File('test/fixtures/vt/$name.raw').readAsBytesSync());
      final ref = File('test/fixtures/vt/$name.ref.txt').readAsLinesSync().map((l) => l.trimRight()).toList();
      final got = vt.snapshot().lines.map((l) => l.text).toList();
      expect(got, ref);
    }, skip: skip);
  }

  test('resizeKeepsTheCursorInside', () {
    final vt = make(20, 10);
    vt.write(_b('\x1b[10;20H'));
    vt.resize(8, 4);
    final s = vt.snapshot();
    expect([s.cols, s.rows, s.lines.length], [8, 4, 4]);
    expect(s.cursorX, lessThan(8));
    expect(s.cursorY, lessThan(4));
  }, skip: skip);

  test('resetClears', () {
    final vt = make(10, 3);
    vt.write(_b('hello\x1b[?2026h'));
    vt.reset();
    final s = vt.snapshot();
    expect(s.lines.map((l) => l.text), everyElement(''));
    expect([s.cursorX, s.cursorY], [0, 0]);
    expect(vt.mode(2026), isFalse);
  }, skip: skip);

  test('synchronizedOutputModeIsReported', () {
    final vt = make(10, 3);
    expect(vt.mode(2026), isFalse);
    vt.write(_b('\x1b[?2026h'));
    expect(vt.mode(2026), isTrue);
    vt.write(_b('\x1b[?2026l'));
    expect(vt.mode(2026), isFalse);
  }, skip: skip);

  test('alternateScreenIsReported', () {
    final vt = make(10, 3);
    vt.write(_b('main'));
    vt.write(_b('\x1b[?1049h'));
    expect(vt.mode(1049), isTrue);
    expect(vt.snapshot().lines[0].text, '');
    vt.write(_b('\x1b[?1049l'));
    expect(vt.mode(1049), isFalse);
    expect(vt.snapshot().lines[0].text, 'main');
  }, skip: skip);

  test('useAfterDisposeThrows', () {
    final vt = Vt(10, 3)..dispose();
    vt.dispose(); // idempotent
    expect(() => vt.write(_b('x')), throwsStateError);
    expect(() => vt.resize(5, 2), throwsStateError);
    expect(vt.reset, throwsStateError);
    expect(() => vt.mode(2026), throwsStateError);
    expect(vt.snapshot, throwsStateError);
  }, skip: skip);

  test('openWithAnotherPathThrows', () {
    Vt.open(_lib); // same path: no-op
    expect(() => Vt.open('libvtshim.so'), throwsStateError);
  }, skip: skip);

  test('unknownModeThrows', () {
    expect(() => make(10, 3).mode(65000), throwsArgumentError);
  }, skip: skip);

  test('snapshotGrowsItsBufferForClusters', () {
    // every cell a 2-codepoint cluster: the extras overflow a grid-sized buffer
    final vt = make(40, 20);
    vt.write(_b(List.filled(40 * 20, 'é').join()));
    final s = vt.snapshot();
    expect(s.lines[19].cells[39].text, 'é');
  }, skip: skip);

  test('rowEqualityIgnoresClusterOffsets', () {
    // row 0 differs (a cluster or not), so row 1's cluster sits at another offset in the two buffers
    final a = make(10, 2)..write(_b('e\u0301\r\nn\u0303x'));
    final b = make(10, 2)..write(_b('a\r\nn\u0303x'));
    final ra = a.snapshot().lines, rb = b.snapshot().lines;
    expect(ra[1], rb[1]);
    expect(ra[1].hashCode, rb[1].hashCode);
    expect(ra[0], isNot(rb[0]));
    final c = make(10, 2)..write(_b('a\r\n\x1b[1mn\u0303x'));
    expect(c.snapshot().lines[1], isNot(rb[1])); // same text, other flags
  }, skip: skip);
}
