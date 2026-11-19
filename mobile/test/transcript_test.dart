import 'dart:convert';
import 'dart:io';

import 'package:elis_mobile/chat/transcript.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _load(String name) =>
    jsonDecode(File('test/fixtures/transcript/$name').readAsStringSync()) as Map<String, dynamic>;

void main() {
  test('decodesEveryItemKind', () {
    final p = TranscriptPage.fromJson(_load('tail.json'));
    expect(p.items.map((i) => i.kind).toSet(), {'user', 'image', 'command', 'commandOutput', 'bash', 'interrupted', 'compactSummary',
        'taskNotification', 'text', 'thinking', 'tool', 'error', 'compact', 'notice', 'hook', 'oversized'});
    expect(p.pending.map((c) => c.source), ['main', 'a1']);
    expect(p.pending.last.agentType, 'general-purpose');
    expect(p.pending.last.agentName, 'scout');
    expect(p.pending.first.agentType, isNull);
    expect(p.items.where((i) => i.rejected).length, 1);
    expect(p.meta!.pr!.prNumber, 446);
    expect(p.commands!.where((c) => c.skill).length, 1);
  });

  test('unknownKindsAndFieldsAreKeptNotFatal', () {
    final p = TranscriptPage.fromJson({'transcript': 't', 'size': 1, 'start': 0, 'next': 1, 'items': [{'kind': 'future', 'uuid': 'u', 'at': 0}]});
    expect(p.items.single.kind, 'future');
    expect(p.meta, isNull);
  });

  test('humanPromptFollowsPromptSourceOrOrigin', () {
    ChatItem u(Map<String, dynamic> m) => ChatItem.fromJson({'kind': 'user', 'uuid': 'u', 'at': 0, ...m});
    expect(u({'promptSource': 'typed'}).isHumanPrompt, isTrue);
    expect(u({'promptSource': 'suggestion_accepted'}).isHumanPrompt, isTrue);
    expect(u({'promptSource': 'system'}).isHumanPrompt, isFalse);
    expect(u({'origin': 'human'}).isHumanPrompt, isTrue);
  });

  test('errorsMapToStates', () {
    expect(TranscriptError.of("unknown command 'session.transcript'"), TranscriptError.hostTooOld);
    expect(TranscriptError.of('invalid request: unknown cmd session.transcript'), TranscriptError.hostTooOld);
    expect(TranscriptError.of('elis on host is too old'), TranscriptError.hostTooOld);
    expect(TranscriptError.of('no adapter'), TranscriptError.noAdapter);
    expect(TranscriptError.of('transcript not found'), TranscriptError.notFound);
  });

  test('wrongTypesReadAsAbsentAndNumbersAcceptStrings', () {
    final p = TranscriptPage.fromJson({'transcript': 7, 'size': '42', 'start': '0', 'next': 'x', 'reset': 'yes', 'items': [
      {'kind': 'tool', 'uuid': 'u', 'at': '12', 'time': 5, 'name': 3, 'running': 'true', 'patch': [{'oldStart': 'a', 'lines': 'x'}], 'exitCode': 2},
      'junk',
    ], 'pending': {'id': 1}, 'meta': 'm', 'commands': [{'name': 'x'}, 4]});
    expect([p.transcript, p.size, p.start, p.next, p.reset, p.meta], ['', 42, 0, 0, false, null]);
    final t = p.items.single;
    expect([t.at, t.time, t.name, t.running, t.exitCode], [12, null, null, false, 2]);
    expect(t.patch!.single.oldStart, 0);
    expect(t.patch!.single.lines, isEmpty);
    expect(p.pending, isEmpty);
    expect(p.commands!.single.name, 'x');
  });
}
