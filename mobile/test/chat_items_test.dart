import 'package:elis_mobile/chat/items.dart';
import 'package:elis_mobile/chat/rows.dart';
import 'package:elis_mobile/chat/transcript.dart';
import 'package:elis_mobile/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';

ChatItem _item(String kind, String uuid, {String? text, String time = '2026-11-20T09:00:00.000Z'}) =>
    ChatItem.fromJson({'kind': kind, 'uuid': uuid, 'time': time, 'text': ?text});

const _reply = 'Run it:\n\n```sh\nflutter test --no-pub\n```\n\nThen **commit**.';

Future<void> _pump(WidgetTester t, ChatItem i, {bool fresh = false}) => t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ListView(key: const Key('list'), children: [
          Builder(builder: (c) => chatRowWidget(c, chatRows([i]).first, fresh: fresh)),
        ]),
      ),
    ));

void main() {
  testWidgets('userBubbleRightAligned', (t) async {
    await _pump(t, _item('user', 'u1', text: 'hi'));
    final bubble = t.getRect(find.byKey(const Key('bubble-u1')));
    final list = t.getRect(find.byKey(const Key('list')));
    expect(list.right - bubble.right, lessThan(24));
    expect(bubble.width, lessThan(list.width / 2));
  });

  testWidgets('assistantTextIsOneMarkdownBody', (t) async {
    await _pump(t, _item('text', 'a1', text: _reply));
    expect(find.byType(MarkdownBody), findsOneWidget);
    final prose = t.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().startsWith('Run it')));
    expect(prose.text.style?.fontFamily, 'Inter');
    final code = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText().contains('flutter test'));
    final span = (t.widget<RichText>(code).text as TextSpan).children!.single;
    expect(span.style?.fontFamily, mono);
    final scroll = t.widget<SingleChildScrollView>(find.ancestor(of: code, matching: find.byType(SingleChildScrollView)));
    expect(scroll.scrollDirection, Axis.horizontal);
  });

  testWidgets('longPressOffersCopyCopyCodeShare', (t) async {
    final messenger = t.binding.defaultBinaryMessenger;
    final clips = <String>[], opens = <MethodCall>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') clips.add((c.arguments as Map)['text'] as String);
      return null;
    });
    messenger.setMockMethodCallHandler(const MethodChannel('elis/open'), (c) async {
      opens.add(c);
      return true;
    });
    addTearDown(() {
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      messenger.setMockMethodCallHandler(const MethodChannel('elis/open'), null);
    });
    await _pump(t, _item('text', 'a1', text: _reply));

    Future<void> pick(String label) async {
      await t.longPress(find.byType(MarkdownBody));
      await t.pumpAndSettle();
      await t.tap(find.text(label));
      await t.pumpAndSettle();
    }

    await pick('Copy');
    await pick('Copy code');
    await pick('Share');
    expect(clips, [_reply, 'flutter test --no-pub']);
    expect(opens.single.method, 'share');
    expect(opens.single.arguments, _reply);
  });

  testWidgets('copyCodeOnlyWithAFence', (t) async {
    await _pump(t, _item('user', 'u1', text: 'plain'));
    await t.longPress(find.byKey(const Key('bubble-u1')));
    await t.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(find.text('Copy code'), findsNothing);
  });

  testWidgets('freshItemsAnimateIn', (t) async {
    await _pump(t, _item('text', 'a1', text: 'new'), fresh: true);
    expect(t.widget<Opacity>(find.byKey(const Key('fresh-a1'))).opacity, 0);
    final slide = t.widget<Transform>(find.descendant(of: find.byKey(const Key('fresh-a1')), matching: find.byType(Transform)).first);
    expect(slide.transform.getTranslation().y, 8);
    await t.pumpAndSettle();
    expect(t.widget<Opacity>(find.byKey(const Key('fresh-a1'))).opacity, 1);

    await _pump(t, _item('text', 'a2', text: 'old'));
    expect(find.byKey(const Key('fresh-a2')), findsNothing);
    expect(find.text('old'), findsOneWidget);
  });

  test('daySeparatorBetweenDays', () {
    final rows = chatRows([
      _item('user', 'u1', text: 'a', time: '2026-11-19T12:00:00.000'),
      _item('text', 'a1', text: 'b', time: '2026-11-19T12:01:00.000'),
      _item('user', 'u2', text: 'c', time: '2026-11-20T12:00:00.000'),
    ]);
    expect([for (final r in rows) r.key], ['u2', 'day-2026-11-20', 'a1', 'u1', 'day-2026-11-19']);
    expect(rows[1].day, DateTime(2026, 11, 20));
    expect(rows[1].item, isNull);
  });

  testWidgets('dayRowShowsTheDate', (t) async {
    await t.pumpWidget(MaterialApp(
        home: Scaffold(body: Builder(builder: (c) => chatRowWidget(c, chatRows([_item('user', 'u1', text: 'a')])[1], fresh: false)))));
    expect(find.text('Fri, Nov 20'), findsOneWidget);
  });
}
