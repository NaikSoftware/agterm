import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elis_mobile/link/decoder.dart';
import 'package:elis_mobile/link/frame.dart';
import 'package:elis_mobile/link/messages.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List hex(String s) => Uint8List.fromList([for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);

String toHex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

LinkKind kind(String name) => LinkKind.values.byName(name);

void main() {
  final v = jsonDecode(File('test/fixtures/phone-link-vectors.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String key) => (v[key] as List).cast<Map<String, dynamic>>();

  Matcher throwsLink(String code) => throwsA(isA<LinkError>().having((e) => e.code, 'code', code));

  test('frames encode to hex and decode back', () {
    for (final f in list('frames')) {
      final frame = LinkFrame(kind(f['kind']), f['channel'], hex(f['payloadHex']));
      expect(toHex(frame.encode()), f['hex'], reason: f['name']);
      final back = LinkDecoder().feed(hex(f['hex'])).single;
      expect((back.kind, back.channel, toHex(back.payload)), (frame.kind, frame.channel, f['payloadHex']), reason: f['name']);
    }
  });

  test('typed factories match the vectors', () {
    String enc(LinkFrame f) => toHex(f.encode());
    final byName = {for (final f in list('frames')) f['name']: f['hex']};
    expect(enc(LinkFrame.credit(2, 16384)), byName['credit 16384']);
    expect(enc(LinkFrame.resize(3, 60, 20)), byName['resize 60x20']);
    expect(enc(LinkFrame.data(0, utf8.encode('hi\n'))), byName['data hi']);
  });

  test('json frames encode to hex and decode to the object', () {
    for (final j in list('json')) {
      final obj = (j['object'] as Map).cast<String, Object>();
      expect(toHex(LinkFrame.json(kind(j['kind']), j['channel'], obj).encode()), j['hex'], reason: j['name']);
      final back = LinkDecoder().feed(hex(j['hex'])).single;
      expect(jsonDecode(utf8.decode(back.payload)), j['object'], reason: j['name']);
    }
  });

  test('streams decode at every chunk size', () {
    for (final s in list('streams')) {
      final bytes = hex(s['hex']);
      for (final size in [1, 2, 3, 7, 9, 10, bytes.length]) {
        final d = LinkDecoder();
        final got = [
          for (var i = 0; i < bytes.length; i += size) ...d.feed(bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size)),
        ];
        expect(
          [for (final f in got) (f.kind.name, f.channel, toHex(f.payload))],
          [for (final f in (s['frames'] as List).cast<Map<String, dynamic>>()) (f['kind'], f['channel'], f['payloadHex'])],
          reason: '${s['name']} chunk $size',
        );
      }
    }
  });

  test('errors throw their code and the decoder stays failed', () {
    for (final e in list('errors')) {
      final d = LinkDecoder();
      expect(() => d.feed(hex(e['hex'])), throwsLink(e['error']), reason: e['name']);
      expect(() => d.feed([0]), throwsLink(e['error']), reason: '${e['name']} stays failed');
    }
  });

  test('payload readers match the vectors', () {
    final byName = {for (final f in list('frames')) f['name']: LinkDecoder().feed(hex(f['hex'])).single};
    expect(byName['credit 16384']!.creditBytes, 16384);
    expect(byName['credit 16384']!.size, isNull);
    expect(byName['grid 120x40']!.size, (cols: 120, rows: 40));
    expect(byName['resize 60x20']!.size, (cols: 60, rows: 20));
    expect(byName['resize 60x20']!.creditBytes, isNull);
    expect(byName['data hi']!.creditBytes, isNull);
    expect(byName['data hi']!.size, isNull);
  });

  test('a max-size data payload decodes', () {
    final frame = LinkFrame.data(2, List.filled(linkMaxPayload, 7));
    final back = LinkDecoder().feed(frame.encode()).single;
    expect((back.kind, back.channel, back.payload.length), (LinkKind.data, 2, linkMaxPayload));
  });

  test('a lone oversize header throws on that feed', () {
    expect(() => LinkDecoder().feed(hex('030000000000010001')), throwsLink('payloadTooLarge'));
  });

  test('upgrade handshake lines', () {
    expect(linkUpgradeRequest, '{"mux":1}\n');
    expect(isLinkUpgradeAnswer('{"ok":true,"mux":1}\n'), isTrue);
    expect(isLinkUpgradeAnswer('{"ok":false}'), isFalse);
    expect(isLinkUpgradeAnswer('nope'), isFalse);
  });
}
