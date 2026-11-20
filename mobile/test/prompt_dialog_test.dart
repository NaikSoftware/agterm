import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_dialog.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

Grid _grid(String name) => gridFromAnsi(File('test/fixtures/grid/$name.ansi').readAsStringSync());

PromptDialog _read(String name) => PromptDialog.read(_grid(name))!;

Map<String, dynamic> _input(String name) =>
    (jsonDecode(File('test/fixtures/grid/$name.pending.json').readAsStringSync()) as List).first['input'] as Map<String, dynamic>;

const _widths = [45, 100];

void main() {
  test('optionsAndNumbers', () {
    for (final w in _widths) {
      final d = _read('card-ask-single-$w');
      expect([for (final o in d.options) o.label],
          ['North Cape', 'Harbour light on the long southern breakwater', 'Island tower', 'Type something.', 'Chat about this'],
          reason: '$w');
      expect([for (final o in d.options) o.number], [1, 2, 3, 4, 5]);
      expect([for (final o in d.options) o.belowRule], [false, false, false, false, true]);
      final n = _read('card-ask-numbers-$w');
      expect([for (final o in n.options.take(2)) (o.number, o.label)], [(1, '7'), (2, '42')]);
    }
  });

  test('multiSelectTicks', () {
    for (final w in _widths) {
      final d = _read('card-ask-multi-ticked-$w');
      expect([for (final o in d.options.where((o) => o.checked != null)) o.checked], [true, false, true, false]);
      final submit = d.options.singleWhere((o) => o.label == 'Submit');
      expect((submit.number, submit.checked), (null, null));
    }
  });

  test('cursorRow', () {
    for (final w in _widths) {
      expect(_read('card-ask-multi-ticked-$w').cursorOption?.number, 1);
      final other = _read('card-ask-other-open-$w').cursorOption!;
      expect((other.number, other.label), (4, 'Type something.'));
    }
  });

  test('reviewLines', () {
    for (final w in _widths) {
      final d = _read('card-ask-review-$w');
      expect(d.review, isTrue);
      expect(d.answers, ['Staging', 'Night']);
      expect(d.reviewQuestions, ['Which environment should the keeper deploy the lamp to?', 'Which shift should the keeper take?']);
      expect([for (final o in d.options) (o.number, o.label)], [(1, 'Submit answers'), (2, 'Cancel')]);
      expect(_read('card-ask-two-$w').review, isFalse);
    }
  });

  test('previewLabelsWithoutTheBox', () {
    for (final w in _widths) {
      final d = _read('card-ask-preview-$w');
      expect(d.preview, isTrue);
      expect([for (final o in d.options) (o.number, o.label)], [(1, 'Ring'), (2, 'Stack'), (null, 'Chat about this')]);
      expect(d.options.last.belowRule, isTrue);
      expect(d.footer, contains('n to add notes'));
      expect(_read('card-ask-single-$w').preview, isFalse);
    }
  });

  test('bashRegions', () {
    final command = _input('card-bash')['command'] as String;
    for (final w in _widths) {
      final d = _read('card-bash-$w');
      expect(norm(d.boxed), norm(command), reason: '$w');
      expect(d.question, contains('Do you want to proceed'));
      expect(norm(d.header), contains('Bashcommand'));
      expect(d.footer, contains('Tab to amend'));
    }
  });

  test('wrappedLabelsJoin', () {
    final d = _read('card-bash-45');
    expect([for (final o in d.options) o.number], [1, 2, 3, 4]);
    expect(d.options[1].label, 'Yes, and always allow access to /tmp from this project');
    expect((d.options[1].row, d.options[1].lastRow), (d.options[1].row, d.options[1].row + 1));
    expect(d.options[2].label, 'Yes, and switch to auto mode');
    expect(d.numbered('No')?.number, 4);
  });

  test('anchorsReadOnlyTheDialogRegion', () {
    for (final (name, fragment, anchor) in [
      ('card-ask-single-45', 'Whichlighthouseshouldthestoryvisit', (PromptDialog d) => d.question),
      ('card-bash-45', 'touch/tmp/elis-fixture', (PromptDialog d) => d.boxed),
    ]) {
      final g = _grid(name);
      final d = PromptDialog.read(g)!;
      final hits = [for (var r = 0; r < g.rows.length; r++) if (norm(g.text(r)).contains(fragment)) r];
      expect(hits.length, greaterThan(1), reason: '$name echoes the anchor above the dialog');
      expect(d.top, greaterThan(hits[hits.length - 2]), reason: name);
      expect(d.top, lessThan(hits.last), reason: name);
      expect(norm(anchor(d)), contains(fragment));
      expect(norm('${d.header}${d.body}${d.question}${d.footer}').split(fragment).length, lessThanOrEqualTo(2));
    }
  });

  test('classicLayout', () {
    final c = _read('card-bash-classic-100'), f = _read('card-bash-100');
    expect([for (final o in c.options) (o.number, o.label, o.cursor)], [for (final o in f.options) (o.number, o.label, o.cursor)]);
    expect(norm(c.boxed), norm(f.boxed));
    expect(norm(c.question), norm(f.question));
  });

  test('noDialogOnIdle', () {
    expect(PromptDialog.read(_grid('idle-placeholder-45')), isNull);
    expect(PromptDialog.read(_grid('working-45')), isNull);
  });

  test('everyCardFixtureParses', () {
    final names = Directory('test/fixtures/grid')
        .listSync()
        .map((f) => f.path.split('/').last)
        .where((n) => n.startsWith('card-') && n.endsWith('.ansi'));
    expect(names.length, 45);
    for (final n in names) {
      final d = _read(n.replaceAll('.ansi', ''));
      expect(d.options.where((o) => o.number != null).length, greaterThanOrEqualTo(2), reason: n);
      expect(d.top, lessThan(d.options.first.row), reason: n);
      expect(d.options.where((o) => o.cursor).length, lessThanOrEqualTo(1), reason: n);
    }
  });
}
