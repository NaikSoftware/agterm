import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Keys client.dart and model.dart send or parse, by the Swift file that owns them.
const wire = {
  'hangarctlKit/MobileCommands.swift': ['h', 'p', 't', 'f', 'n', 'b'],
  'hangarctlKit/PhoneSession.swift': ['auth', 'id', 'ok', 'result'],
  'HangarCore/ControlResponse.swift': ['ok', 'result', 'error'],
  'HangarCore/ControlProtocol.swift': ['cmd', 'target', 'args', 'window', 'run', 'after', 'limit', 'events', 'tree', 'windows'],
  'HangarCore/ControlEvents.swift': ['run', 'next', 'items', 'kind', 'session', 'payload', 'status', 'name', 'title', 'body'],
  'HangarCore/ControlProjection+Tree.swift': ['workspaces', 'id', 'name', 'open', 'active'],
  'HangarCore/ControlProjection.swift': [
    'id', 'name', 'status', 'agent', 'foreground', 'cwd', 'parent', 'context', 'tint', 'unseen', 'flagged', 'active',
    'statusBlink', 'hasSplit', 'split', 'collapsed', 'rememberedFolder', 'sessions',
  ],
};

void main() {
  for (final MapEntry(key: file, value: keys) in wire.entries) {
    test('$file declares every key the phone uses', () {
      final source = File('../macos/HangarCore/Sources/$file').readAsStringSync();
      for (final k in keys) {
        // a stored Codable property, a JSON literal key, or a pair-link query parameter
        final declared = RegExp('(let|var) $k\\b|"$k"|[?&")]$k=').hasMatch(source);
        expect(declared, isTrue, reason: '$k is not in $file');
        expect(k.toLowerCase(), isNot(contains('agterm')));
      }
    });
  }
}
