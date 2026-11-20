import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/grid.dart';
import 'package:elis_mobile/chat/prompt_dialog.dart';
import 'package:elis_mobile/chat/prompt_match.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/ansi.dart';

const _dir = 'test/fixtures/grid';

PromptDialog _read(String name) => PromptDialog.read(gridFromAnsi(File('$_dir/$name.ansi').readAsStringSync()))!;

List<Map<String, dynamic>> _json(String name) => [
  for (final m in jsonDecode(File('$_dir/$name.pending.json').readAsStringSync()) as List) m as Map<String, dynamic>,
];

PendingCall _call(String name, [Map<String, dynamic> Function(Map<String, dynamic>)? edit]) {
  final m = _json(name).first;
  return PendingCall.fromJson(edit == null ? m : edit(jsonDecode(jsonEncode(m)) as Map<String, dynamic>));
}

Map<String, dynamic> _withInput(Map<String, dynamic> m, void Function(Map<String, dynamic>) f) {
  f(m['input'] as Map<String, dynamic>);
  return m;
}

void main() {
  test('eachFixtureMatchesItsCall', () {
    final grids = [
      for (final f in Directory(_dir).listSync())
        if (RegExp(r'/card-.*\.ansi$').hasMatch(f.path) && !f.path.contains('card-plan-nofile')) f.uri.pathSegments.last,
    ]..sort();
    expect(grids.length, greaterThan(40));
    for (final g in grids) {
      final name = g.replaceFirst(RegExp(r'\.ansi$'), '');
      final call = _call(name.replaceFirst(RegExp(r'-\d+$'), ''));
      final m = matchPrompt(_read(name), [call]);
      expect(m?.call.id, call.id, reason: name);
      expect(m?.kind, promptKind(call), reason: name);
      expect(m?.kind, isNotNull, reason: name);
    }
  });

  test('eachFixtureMatchesWithoutItsTitleRule', () {
    for (final f in Directory(_dir).listSync()) {
      if (!RegExp(r'/card-.*\.ansi$').hasMatch(f.path) || f.path.contains('card-plan-nofile')) continue;
      final name = f.uri.pathSegments.last.replaceFirst(RegExp(r'\.ansi$'), '');
      final g = gridFromAnsi(File(f.path).readAsStringSync());
      final title = g.rows.lastIndexWhere((r) => r.text.trim().isNotEmpty);
      final call = _call(name.replaceFirst(RegExp(r'-\d+$'), ''));
      expect(matchPrompt(PromptDialog.read(Grid(g.rows.sublist(0, title))), [call])?.call.id, call.id, reason: name);
    }
  });

  test('askQuestionIndex', () {
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-ask-two-$w'), [_call('card-ask-two')])!.question, 0);
      expect(matchPrompt(_read('card-ask-two-second-$w'), [_call('card-ask-two-second')])!.question, 1);
      final review = matchPrompt(_read('card-ask-review-$w'), [_call('card-ask-review')])!;
      expect((review.kind, review.question), (PromptKind.ask, null));
    }
  });

  test('otherCallDoesNotMatch', () {
    final other = _call('card-bash', (m) => _withInput(m, (i) => i['command'] = 'touch /tmp/other.txt'));
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [other]), isNull);
    }
  });

  test('twoMatchesGoToPanel', () {
    final a = _call('card-bash');
    final b = _call('card-bash', (m) => m..['id'] = 'toolu_second');
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [a, b]), isNull);
    }
  });

  test('parallelBatchPicksTheShownCall', () {
    final bash = _call('card-bash');
    expect(matchPrompt(_read('card-bash-45'), [bash, _call('card-write')])?.call.id, bash.id);
  });

  test('bashPrefixCommandDoesNotMatch', () {
    final shown = _call('card-bash');
    final prefix = _call('card-bash', (m) {
      m['id'] = 'toolu_prefix';
      return _withInput(m, (i) => i['command'] = 'touch /tmp/elis-fixture-lantern-keeper');
    });
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [prefix]), isNull);
      expect(matchPrompt(_read('card-bash-$w'), [prefix, shown])?.call.id, shown.id);
    }
  });

  test('mcpWithoutArgumentsHasNoCard', () {
    final empty = _call('card-mcp', (m) => m..['input'] = <String, dynamic>{});
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-mcp-$w'), [empty]), isNull);
    }
  });

  test('mcpDoesNotAnchorAnotherToolsDialog', () {
    final mcp = _call('card-mcp', (m) => m..['input'] = <String, dynamic>{'path': 'tmp'});
    final described = _call('card-mcp', (m) => m..['input'] = <String, dynamic>{'items': 'topic.instructions'});
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [mcp]), isNull, reason: '$w');
      expect(matchPrompt(_read('card-write-$w'), [mcp]), isNull, reason: '$w');
      expect(matchPrompt(_read('card-mcp-$w'), [described]), isNull, reason: '$w');
    }
  });

  test('mcpShortValueDoesNotAnchorABashDialog', () {
    final one = _call('card-mcp', (m) => m..['input'] = <String, dynamic>{'n': 1});
    for (final w in [45, 100]) {
      final ansi = File('$_dir/card-bash-$w.ansi').readAsStringSync().replaceAll('lantern', 'lant1rn');
      final bash = PromptDialog.read(gridFromAnsi(ansi))!;
      expect(norm(bash.boxed), contains('1'), reason: '$w');
      expect(matchPrompt(bash, [one]), isNull, reason: '$w');
    }
  });

  test('mcpValueMustFollowItsKey', () {
    final inside = _call('card-mcp', (m) => m..['input'] = <String, dynamic>{'items': 'topic'});
    final otherKey = _call(
      'card-mcp',
      (m) => m
        ..['input'] = <String, dynamic>{
          'topics': ['topic.index'],
        },
    );
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-mcp-$w'), [inside]), isNull, reason: '$w');
      expect(matchPrompt(_read('card-mcp-$w'), [otherKey]), isNull, reason: '$w');
    }
  });

  test('subagentSourceNeedsTheHeader', () {
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-subagent-bash-$w'), [_call('card-subagent-bash', (m) => m..['source'] = 'main')]), isNull);
      expect(
        matchPrompt(_read('card-bash-$w'), [
          _call(
            'card-bash',
            (m) => m
              ..['source'] = 'a1'
              ..['agentType'] = 'general-purpose',
          ),
        ]),
        isNull,
      );
    }
  });

  test('subagentHeaderNamesTypeOrName', () {
    PendingCall sub({String? type, String? name, String id = 'toolu_sub'}) => _call('card-subagent-bash', (m) {
      m.remove('agentType');
      return m
        ..['id'] = id
        ..['agentType'] = type
        ..['agentName'] = name;
    });
    for (final w in [45, 100]) {
      final d = _read('card-subagent-bash-$w');
      expect(matchPrompt(d, [sub(type: 'general-purpose')]), isNotNull, reason: '$w');
      expect(matchPrompt(d, [sub(name: 'general-purpose')]), isNotNull, reason: '$w');
      expect(matchPrompt(d, [sub(type: 'Explore')]), isNull, reason: '$w');
      expect(matchPrompt(d, [sub()]), isNull, reason: '$w');
      expect(
        matchPrompt(d, [sub(type: 'general-purpose'), sub(type: 'general-purpose', id: 'toolu_other')]),
        isNull,
        reason: '$w',
      );
    }
  });

  test('clippedInputHasNoCard', () {
    final clipped = _call('card-bash', (m) {
      m.remove('input');
      return m..['clipped'] = true;
    });
    expect(clipped.input, isNull);
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [clipped]), isNull);
    }
  });

  test('planAnchorsOnHeadingWithoutFile', () {
    final call = _call('card-plan', (m) => _withInput(m, (i) => i.remove('planFilePath')));
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-plan-$w'), [call])?.kind, PromptKind.plan, reason: '$w');
    }
  });

  test('exitPlanWithoutPlanHasNoCard', () {
    expect(matchPrompt(_read('card-plan-nofile-45'), [_call('card-plan-nofile')]), isNull);
  });

  test('webFetchTrailingSlash', () {
    final call = _call('card-webfetch', (m) => _withInput(m, (i) => i['url'] = 'https://example.org'));
    final page = _call('card-webfetch', (m) => _withInput(m, (i) => i['url'] = 'https://example.org/page'));
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-webfetch-$w'), [call]), isNotNull, reason: '$w');
      expect(matchPrompt(_read('card-webfetch-$w'), [page]), isNull, reason: '$w');
    }
  });

  test('unknownToolHasNoKind', () {
    final nb = _call('card-bash', (m) => m..['name'] = 'NotebookEdit');
    expect(promptKind(nb), isNull);
    for (final w in [45, 100]) {
      expect(matchPrompt(_read('card-bash-$w'), [nb]), isNull);
    }
  });
}
