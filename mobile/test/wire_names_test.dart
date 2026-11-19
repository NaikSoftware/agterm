import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Keys client.dart and model.dart send or parse, by the Swift file that owns them.
const wire = {
  'elisctlKit/MobileCommands.swift': ['h', 'p', 't', 'f', 'n', 'b'],
  'elisctlKit/PhoneSession.swift': ['auth', 'id', 'ok', 'result'],
  'ElisCore/ControlResponse.swift': ['ok', 'result', 'error'],
  'ElisCore/ControlProtocol.swift': ['cmd', 'target', 'args', 'window', 'run', 'after', 'limit', 'events', 'tree', 'windows'],
  'ElisCore/ControlEvents.swift': ['run', 'next', 'items', 'kind', 'session', 'payload', 'status', 'name', 'title', 'body'],
  'ElisCore/ControlProjection+Tree.swift': ['workspaces', 'id', 'name', 'open', 'active'],
  'ElisCore/ControlProjection.swift': [
    'id', 'name', 'status', 'agent', 'foreground', 'cwd', 'parent', 'context', 'tint', 'unseen', 'flagged', 'active',
    'statusBlink', 'hasSplit', 'split', 'collapsed', 'rememberedFolder', 'sessions', 'agentSessionId', 'remoteHost',
  ],
};

// Keys whose Swift side has not landed yet, with the reason the test is skipped.
const pending = {
  'ElisCore/ControlProjection.swift': (['agentPane'], 'plan A adds agentPane'),
};

void main() {
  for (final MapEntry(key: file, value: (keys, reason)) in pending.entries) {
    test('$file declares the pending keys', () => expectDeclared(file, keys), skip: reason);
  }
  for (final MapEntry(key: file, value: keys) in wire.entries) {
    test('$file declares every key the phone uses', () => expectDeclared(file, keys));
  }
}

void expectDeclared(String file, List<String> keys) {
  final source = File('../macos/ElisCore/Sources/$file').readAsStringSync();
  for (final k in keys) {
    // a stored Codable property, a JSON literal key, or a pair-link query parameter
    final declared = RegExp('(let|var) $k\\b|"$k"|[?&")]$k=').hasMatch(source);
    expect(declared, isTrue, reason: '$k is not in $file');
    expect(k.toLowerCase(), isNot(contains('agterm')));
  }
}
