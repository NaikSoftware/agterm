import 'package:agterm_mobile/client.dart';
import 'package:agterm_mobile/model.dart';
import 'package:agterm_mobile/screens/prompt.dart';
import 'package:agterm_mobile/theme.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AutoFit', () {
    test('fits a visible screen and gives the grid back when hidden', () {
      final f = AutoFit();
      expect(f.next(fitted: false, visible: true), isTrue);
      expect(f.next(fitted: true, visible: true), isNull);
      expect(f.next(fitted: true, visible: false), isFalse);
      expect(f.next(fitted: false, visible: false), isNull);
    });

    test('a manual restore or the computer taking the grid back stops refitting', () {
      final f = AutoFit()..wanted = false;
      expect(f.next(fitted: true, visible: true), isFalse);
      expect(f.next(fitted: false, visible: true), isNull);
    });
  });

  group('macOS server compat', () {
    test('blink reads statusBlink when blink is absent', () {
      expect(Session({'statusBlink': true}, 'w', 'W').blink, isTrue);
      expect(Session({'blink': true}, 'w', 'W').blink, isTrue);
      expect(Session({}, 'w', 'W').blink, isFalse);
    });

    test('shortens /home and /Users prefixes', () {
      expect(shortHome('/home/ann/src'), '~/src');
      expect(shortHome('/Users/ann'), '~');
      expect(shortHome('/opt/x'), '/opt/x');
    });

    test('expands ~ only as a leading path element', () {
      expect(expandHome('~/src', '/Users/ann'), '/Users/ann/src');
      expect(expandHome('~', '/Users/ann'), '/Users/ann');
      expect(expandHome('~x/a', '/Users/ann'), '~x/a');
    });

    test('parses palette names and hex tints', () {
      expect(tintColor('teal'), isNotNull);
      expect(tintColor('red'), isNotNull);
      expect(tintColor('#ff8800'), const Color(0xFFFF8800));
      expect(tintColor('#ff88'), isNull);
      expect(tintColor(''), isNull);
    });
  });

  group('Pairing.parse', () {
    const fp = 'd6804234939ad32471883bb5743cf3e435d24d0e1a02085f0adf7a51634cb443';
    const token = 'B9nEPMC4LDwT26URUTdmlho5YnA9mIq2gvBL86UnvVo';

    test('reads the link agtermctl mobile serve prints', () {
      final p = Pairing.parse('agterm://pair?h=192.168.1.20&p=8765&t=$token&f=$fp&n=naik-station')!;
      expect((p.host, p.port, p.token, p.fingerprint, p.name), ('192.168.1.20', 8765, token, fp, 'naik-station'));
    });

    test('names the computer by its address without n', () {
      expect(Pairing.parse('agterm://pair?h=10.0.2.2&p=1&t=$token&f=${fp.toUpperCase()}')!.name, '10.0.2.2');
    });

    test('refuses anything else', () {
      for (final bad in [
        '',
        'https://pair?h=a&p=1&t=$token&f=$fp',
        'agterm://pair?h=a&p=0&t=$token&f=$fp',
        'agterm://pair?h=a&p=8765&t=short&f=$fp',
        'agterm://pair?h=a&p=8765&t=$token&f=abc',
        'agterm://pair?p=8765&t=$token&f=$fp',
      ]) {
        expect(Pairing.parse(bad), isNull, reason: bad);
      }
    });

    test('round-trips through JSON', () {
      final p = Pairing.parse('agterm://pair?h=h&p=2&t=$token&f=$fp')!;
      expect(Pairing.fromJson(p.toJson()).toJson(), p.toJson());
    });
  });

  group('promptOptions', () {
    test("reads Claude Code's boxed permission prompt", () {
      const screen = '''
╭──────────────────────────────────────╮
│ Bash command                         │
│   cmake --build build -j8            │
│ Do you want to proceed?              │
│ ❯ 1. Yes                             │
│   2. Yes, and don't ask again for    │
│      cmake commands                  │
│   3. No, and tell Claude what to do  │
╰──────────────────────────────────────╯''';
      expect(promptOptions(screen).map((o) => o.key), ['1', '2', '3']);
      expect(promptOptions(screen).first.label, 'Yes');
    });

    test('a later list replaces an earlier one and gaps do not count', () {
      expect(promptOptions('1. old\n2. old\nthen\n1. A\n2. B').map((o) => o.label), ['A', 'B']);
      expect(promptOptions('1. A\n3. C'), isEmpty);
      expect(promptOptions('step 1. done'), isEmpty);
    });

    test('offers y/n for a trailing [y/N] question', () {
      expect(promptOptions('Overwrite file? [y/N]').map((o) => o.key), ['y', 'n']);
      expect(promptOptions('Overwrite? [y/N]\n\$ '), isEmpty);
    });

    test('long labels are cut', () {
      expect(promptOptions('1. ${'x' * 40}\n2. b').first.label.length, 24);
    });
  });

  test('promptTail drops frames and blank rows', () {
    expect(promptTail('╭────╮\n│ a  │\n\n│ b  │\n╰────╯', rows: 6), 'a\nb');
    expect(promptTail('1\n2\n3\n4', rows: 2), '3\n4');
  });

  test('Alert.of: blocked, completed and notify alert; other events do not', () {
    Alert? of(String kind, Map p) => Alert.of({'kind': kind, 'session': 's1', 'payload': p});
    final b = of('status', {'status': 'blocked', 'name': 'claude'})!;
    expect((b.sessionId, b.title, b.body, b.status), ('s1', 'claude', 'needs your input', 'blocked'));
    expect(of('status', {'status': 'completed'})!.body, 'finished');
    final n = of('notify', {'title': 'Build', 'body': 'green'})!;
    expect((n.title, n.body, n.status), ('Build', 'green', 'notify'));
    expect(of('status', {'status': 'active'}), isNull);
    expect(of('lifecycle', {}), isNull);
  });
}
