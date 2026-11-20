import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// Keys client.dart and model.dart send or parse, by the Swift file that owns them.
const wire = {
  'elisctlKit/MobileCommands.swift': ['h', 'p', 't', 'f', 'n', 'b'],
  'elisctlKit/PhoneSession.swift': ['auth', 'id', 'ok', 'result'],
  'ElisCore/ControlResponse.swift': ['ok', 'result', 'error'],
  'ElisCore/ControlProtocol.swift': ['cmd', 'target', 'args', 'window', 'run', 'after', 'limit', 'events', 'tree', 'windows'],
  'ElisCore/ControlEvents.swift': ['run', 'next', 'items', 'kind', 'session', 'payload', 'status', 'name', 'title', 'body'],
  'ElisCore/PhoneLink/PhoneLinkPages.swift': [
    'page', 'command', 'res', 'reply', 'fetch', 'bridge', 'state', 'closed', 'elis:content', 'elis:script',
    't', 'id', 'seq', 'action', 'sizePercent', 'mime', 'data', 'end', 'error', 'response', 'path', 'line', 'load', 'title',
    'current', 'canGoBack', 'appliedSeq', 'hidden', 'dismissed', 'kind', 'url', 'adapter', 'helper', 'javascript', 'chromeless', 'browse',
  ],
  'elisctlKit/PhoneLinkSession.swift': ['present'],
  'ElisCore/ControlProjection+Tree.swift': ['workspaces', 'id', 'name', 'open', 'active'],
  'ElisCore/ControlProjection.swift': [
    'id', 'name', 'status', 'agent', 'foreground', 'cwd', 'parent', 'context', 'tint', 'unseen', 'flagged', 'active',
    'statusBlink', 'hasSplit', 'split', 'collapsed', 'rememberedFolder', 'sessions',
  ],
};

void main() {
  for (final MapEntry(key: file, value: keys) in wire.entries) {
    test('$file declares every key the phone uses', () {
      final source = File('../macos/ElisCore/Sources/$file').readAsStringSync();
      for (final k in keys) {
        // a stored Codable property, a CodingKey case, a JSON literal key, or a pair-link query parameter
        final declared = RegExp('(let|var) $k\\b|case [\\w, ]*\\b$k\\b|"$k"|[?&")]$k=').hasMatch(source);
        expect(declared, isTrue, reason: '$k is not in $file');
        expect(k.toLowerCase(), isNot(contains('agterm')));
      }
    });
  }
}
