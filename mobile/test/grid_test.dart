import 'dart:io';

import 'package:elis_mobile/chat/grid.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

String _fx(String name) => File('test/fixtures/grid/$name.ansi').readAsStringSync();

void main() {
  test('ansiCaptureKeepsDimCells', () {
    final g = gridFromAnsi(_fx('idle-placeholder-45'));
    final r = [for (var i = 0; i < g.rows.length; i++) i].lastWhere((i) => g.text(i).startsWith('❯ '));
    expect(g.text(r), startsWith('❯ Try'));
    expect(g.bright(r).trim(), '❯');
  });
  test('textGridHasNoColours', () {
    final g = Grid.text('a\n❯ hi');
    expect(g.colours, isFalse);
    expect(g.bright(1), '❯ hi');
  });
  test('normDropsAllWhitespace', () => expect(norm(' a b\n c '), 'abc'));
  test('everyFixtureFitsItsWidth', () {
    for (final f in Directory('test/fixtures/grid').listSync().whereType<File>().where((f) => f.path.endsWith('.ansi'))) {
      final width = int.parse(RegExp(r'-(\d+)\.ansi$').firstMatch(f.path)![1]!);
      final g = gridFromAnsi(f.readAsStringSync());
      expect(g.rows.length, width == 45 ? 40 : 30, reason: f.path);
      expect(g.rows.every((r) => r.cells.length <= width), isTrue, reason: f.path);
    }
  });
}
