// On an Android device or emulator (needs libvtshim.so in the APK):
//   flutter test integration_test/term_view_test.dart -d <device> --no-pub
// The test keeps the screen up for a while at the end so a screenshot can be taken with
//   adb -s <device> exec-out screencap -p > shot.png
import 'dart:convert';
import 'dart:typed_data';

import 'package:elis_mobile/terminal/terminal_view.dart';
import 'package:elis_mobile/terminal/vt.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _emoji = ['❤️', '☺️', '✔️', '✅', '❌', '⭐', '👩‍💻', '👍🏽'];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Term view draws colour, CJK, emoji and combining marks', (t) async {
    Vt.open();
    final vt = Vt(40, 12);
    addTearDown(vt.dispose);
    vt.write(Uint8List.fromList(utf8.encode([
      '\x1b[31mred\x1b[0m \x1b[1;32mbold green\x1b[0m \x1b[4;34munder\x1b[0m \x1b[7minv\x1b[0m',
      '漢字 \x1b[33m漢字\x1b[0m end',
      _emoji.join(' '),
      'é é́́ éx',
      '\x1b[4m   \x1b[0mgap',
    ].join('\r\n'))));
    final s = vt.snapshot();

    String cellsOf(int y) => s.lines[y].cells.map((c) => c.text).join('|');
    final cjk = s.lines[1].cells;
    expect([cjk[0].text, cjk[0].wide, cjk[1].spacer, cjk[2].text, cjk[2].wide], ['漢', true, true, '字', true]);
    final line = s.lines[2].cells.where((c) => c.text.isNotEmpty).map((c) => c.text).where((x) => x != ' ').toList();
    expect(line, _emoji);
    debugPrint('EMOJI wide flags: ${s.lines[2].cells.where((c) => c.text.isNotEmpty && c.text != ' ').map((c) => '${c.text}:${c.wide}').join(' ')}');
    expect(s.lines[3].cells[0].text, 'é');
    expect(s.lines[3].cells[2].text, 'é́́');
    expect(s.lines[3].cells[4].text, 'é');
    debugPrint('LINE3 ${cellsOf(3)}');
    expect(s.lines[4].cells[0].underline, true);

    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(color: C.term, child: SafeArea(child: Align(alignment: Alignment.topLeft, child: TerminalView(snapshot: s, hold: false)))),
    ));
    await t.pump(const Duration(milliseconds: 300));
    debugPrint('SCREEN READY');
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 25)));
  });
}
