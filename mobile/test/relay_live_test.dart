// Runs against a live `elisctl mobile serve` when ELIS_PAIR_LINK is set; skipped otherwise.
import 'dart:io';

import 'package:elis_mobile/client.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final link = Platform.environment['ELIS_PAIR_LINK'];
  test('relay answers control commands with the pinned certificate', () async {
    final p = Pairing.parse(link!)!;
    final c = await Connection.open(p);
    final tree = await c.call('tree');
    expect(tree['tree']['workspaces'], isNotEmpty);
    final created = await c.call('session.new', args: {'name': 'from-phone', 'noSelect': true});
    expect(created['id'], isNotNull);
    await c.call('session.type', target: created['id'], args: {'text': 'echo phone-ok\r'});
    await Future.delayed(const Duration(milliseconds: 800));
    final text = await c.call('session.text', target: created['id']);
    expect('$text', contains('phone-ok'));
    final grid = await c.call('session.grid', target: created['id'], args: {'columns': 40, 'rows': 60});
    expect([grid['columns'], grid['rows']], [40, 60]); // Fit to phone: the phone's grid
    await c.call('session.grid', target: created['id'], args: {'reset': true});
    await expectLater(c.call('session.info', target: 'nope'), throwsA(isA<ElisError>()));
    c.close();
    final bad = Pairing(name: 'x', host: p.host, port: p.port, token: 'A' * 43, fingerprint: p.fingerprint);
    await expectLater(Connection.open(bad), throwsA(isA<ElisError>().having((e) => e.message, 'message', contains('revoked'))));
    final wrongCert = Pairing(name: 'x', host: p.host, port: p.port, token: p.token, fingerprint: '0' * 64);
    await expectLater(Connection.open(wrongCert), throwsA(isA<ElisError>().having((e) => e.message, 'message', contains('certificate'))));
  }, skip: link == null ? 'set ELIS_PAIR_LINK' : false);
}
