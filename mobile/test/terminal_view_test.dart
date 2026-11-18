import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/terminal/row_cache.dart';
import 'package:elis_mobile/terminal/terminal_view.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

const _lib = 'build/vtshim/libvtshim.dylib';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  final missing = !File(_lib).existsSync();
  // testWidgets takes a bool skip only: run tool/build-vtshim.sh when these skip
  setUpAll(() async {
    if (missing) return;
    Vt.open(_lib);
    // flutter test draws with its test font unless the real ones are loaded
    for (final (family, file) in [('JetBrainsMono', 'JetBrainsMono'), ('NotoSansSymbols2', 'NotoSansSymbols2')]) {
      await (FontLoader(family)..addFont(rootBundle.load('assets/fonts/$file.ttf'))).load();
    }
  });

  Vt make(int cols, int rows) {
    final vt = Vt(cols, rows);
    addTearDown(vt.dispose);
    return vt;
  }

  Future<void> show(WidgetTester tester, VtSnapshot? s, {bool hold = false, double width = 400}) => tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(alignment: Alignment.topLeft, child: SizedBox(width: width, child: TerminalView(snapshot: s, hold: hold))),
        ),
      );

  TerminalPainter painter(WidgetTester tester) => tester
      .widget<CustomPaint>(find.descendant(of: find.byType(TerminalView), matching: find.byType(CustomPaint)))
      .painter! as TerminalPainter;

  testWidgets('rowCacheRepaintsOnlyChangedRows', (tester) async {
    final vt = make(20, 5)..write(_b('one\r\ntwo\r\nthree\r\nfour'));
    final m = CellMetrics.fit(400, 20);
    final cache = RowCache();
    addTearDown(cache.dispose);
    void frame(VtSnapshot s) {
      for (var y = 0; y < s.rows; y++) {
        cache.rowPicture(y, s.lines[y], m);
      }
      cache.endFrame();
    }

    frame(vt.snapshot());
    final first = cache.built;
    expect(first, 5); // four text rows, the blank row
    vt.write(_b('\x1b[2;1Htwo!'));
    frame(vt.snapshot());
    expect(cache.built - first, 1);
    // a scroll moves rows to other y: their pictures are reused, only the new bottom row is drawn
    vt.write(_b('\x1b[5;1Hfive\r\n'));
    final before = cache.built;
    frame(vt.snapshot());
    expect(cache.built - before, 1); // "five" (the new blank row matches the old one)
    expect(cache.live, lessThanOrEqualTo(5));
  }, skip: missing);

  testWidgets('paintsWideAndCombinedCells', (tester) async {
    final vt = make(100, 30)..write(File('test/fixtures/vt/shell.raw').readAsBytesSync());
    tester.view.physicalSize = const Size(1000, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await show(tester, vt.snapshot(), width: 1000);
    await expectLater(find.byType(TerminalView), matchesGoldenFile('goldens/terminal_shell.png'));
  }, skip: missing);

  testWidgets('cursorDrawnAtItsCell', (tester) async {
    final vt = make(10, 3)..write(_b('ab\r\nc'));
    await show(tester, vt.snapshot());
    final m = CellMetrics.fit(400, 10);
    expect(
      find.descendant(of: find.byType(TerminalView), matching: find.byType(CustomPaint)),
      paints
        ..rect(rect: Rect.fromLTWH(0, 0, 400, 3 * m.h)) // the background
        ..rect(rect: Rect.fromLTWH(m.w, m.h, m.w, m.h)),
    );
  }, skip: missing);

  testWidgets('holdKeepsTheLastFrame', (tester) async {
    final vt = make(10, 3)..write(_b('a'));
    final a = vt.snapshot();
    await show(tester, a);
    vt.write(_b('b'));
    final b = vt.snapshot();
    await show(tester, b, hold: true);
    expect(painter(tester).snapshot, same(a));
    await tester.pump(const Duration(milliseconds: 999));
    expect(painter(tester).snapshot, same(a));
    await tester.pump(const Duration(milliseconds: 1));
    expect(painter(tester).snapshot, same(b)); // released after 1 s though the hold stays
    vt.write(_b('c'));
    final c = vt.snapshot();
    await show(tester, c);
    expect(painter(tester).snapshot, same(c));
  }, skip: missing);
}
