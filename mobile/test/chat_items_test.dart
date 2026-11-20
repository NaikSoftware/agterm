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

Future<void> _pump(WidgetTester t, ChatItem i, {bool fresh = false}) => _pumpRow(t, chatRows([i]).first, fresh: fresh);

Future<void> _pumpRow(WidgetTester t, ChatRow r, {bool fresh = false, bool exited = false, bool stale = false}) => t.pumpWidget(MaterialApp(
      theme: buildTheme(),
      home: Scaffold(
        body: ListView(key: const Key('list'), children: [
          Builder(builder: (c) => chatRowWidget(c, r, fresh: fresh, exited: exited, stale: stale)),
        ]),
      ),
    ));

ChatItem _tool(String uuid, String name, [Map<String, dynamic> fields = const {}]) =>
    ChatItem.fromJson({'kind': 'tool', 'uuid': uuid, 'name': name, ...fields});

ChatItem _ro(String uuid, String name) => _tool(uuid, name, {'readOnly': true});

Color? _color(WidgetTester t, String text) =>
    t.widget<RichText>(find.descendant(of: find.text(text), matching: find.byType(RichText))).text.style?.color;

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
  test('threeReadOnlyCallsGroup', () {
    final three = chatRows([_ro('r1', 'Read'), _ro('g1', 'Grep'), _ro('g2', 'Glob')]);
    expect(three.single.key, 'group-r1');
    expect(three.single.item, isNull);
    expect(groupLabel(three.single.group), 'Read 1 file · Searched 2');
    expect([for (final r in chatRows([_ro('r1', 'Read'), _ro('g1', 'Grep')])) r.key], ['g1', 'r1']);
    final grown = chatRows([_ro('r1', 'Read'), _ro('g1', 'Grep'), _ro('g2', 'Glob'), _ro('r2', 'Read')]);
    expect(grown.single.key, three.single.key);
    expect(groupLabel(grown.single.group), 'Read 2 files · Searched 2');
  });

  testWidgets('groupRowExpandsToItsTools', (t) async {
    await _pumpRow(t, chatRows([_ro('r1', 'Read'), _ro('g1', 'Grep'), _ro('g2', 'Glob')]).single);
    expect(find.text('Grep'), findsNothing);
    await t.tap(find.text('Read 1 file · Searched 2'));
    await t.pumpAndSettle();
    expect(find.text('Grep'), findsOneWidget);
    expect(find.text('Glob'), findsOneWidget);
  });

  test('editBashNeverGroup', () {
    final rows = chatRows([_ro('r1', 'Read'), _ro('r2', 'Read'), _tool('e1', 'Edit'), _ro('r3', 'Read')]);
    expect([for (final r in rows) r.key], ['r3', 'e1', 'r2', 'r1']);
  });

  testWidgets('toolRowShowsNameArgMark', (t) async {
    await _pump(t, _tool('b1', 'Bash', {'arg': 'Run unit tests', 'mark': 'ok'}));
    expect(find.text('Bash'), findsOneWidget);
    expect(find.text('Run unit tests'), findsOneWidget);
    expect(find.text('✓'), findsOneWidget);
    final style = t.widget<RichText>(find.descendant(of: find.text('Run unit tests'), matching: find.byType(RichText))).text.style!;
    expect(style.color, C.muted);
    expect(style.fontSize, lessThan(14));
    await _pump(t, _tool('b2', 'Bash', {'arg': 'Run unit tests', 'mark': 'exit 1'}));
    expect(find.text('✗ exit 1'), findsOneWidget);
    expect([for (final m in ['error', 'done', '+12 −3', null]) markText(m)], ['✗', '✓ done', '+12 −3', '']);
  });

  testWidgets('tapExpandsClippedOutput', (t) async {
    await _pump(t, _tool('b1', 'Bash', {'arg': 'Run unit tests', 'mark': 'ok', 'output': 'line 1\nline 2', 'clipped': true}));
    expect(find.text('line 1\nline 2'), findsNothing);
    await t.tap(find.text('Bash'));
    await t.pumpAndSettle();
    expect(find.text('line 1\nline 2'), findsOneWidget);
    expect(find.text('Full output in Term'), findsOneWidget);
    expect(find.ancestor(of: find.text('line 1\nline 2'), matching: find.byType(AnimatedSize)), findsOneWidget);
  });

  testWidgets('diffRendersHunks', (t) async {
    final long = '+${'wrapped ' * 30}';
    await _pump(
        t,
        _tool('e1', 'Edit', {
          'arg': 'model.dart',
          'mark': '+2 −1',
          'file': 'lib/model.dart',
          'patch': [
            {'oldStart': 1, 'oldLines': 2, 'newStart': 1, 'newLines': 2, 'lines': [' keep', '-old line', '+new line']},
            {'oldStart': 40, 'oldLines': 0, 'newStart': 40, 'newLines': 1, 'lines': [long]},
          ],
        }));
    await t.tap(find.text('Edit'));
    await t.pumpAndSettle();
    expect(find.textContaining('lib/model.dart'), findsNWidgets(2));
    expect(_color(t, '-old line'), C.danger);
    expect(_color(t, '+new line'), C.completedText);
    expect(_color(t, ' keep'), isNot(anyOf(C.danger, C.completedText)));
    expect(find.ancestor(of: find.text(long), matching: find.byType(SingleChildScrollView)), findsNothing);
    expect(t.getSize(find.text(long)).height, greaterThan(40));
  });

  test('subagentStates', () {
    final open = _tool('a1', 'Agent', {'running': true, 'mark': 'running'});
    SubagentState of(ChatItem i, {bool interruptedAfter = false, bool exited = false, bool stale = false}) =>
        subagentState(i, interruptedAfter: interruptedAfter, exited: exited, stale: stale);
    expect(of(open), SubagentState.running);
    expect(of(_tool('a2', 'Agent', {'mark': 'done'})), SubagentState.finished);
    expect(of(_tool('a3', 'Agent', {'mark': 'error'})), SubagentState.finished);
    expect(of(open, interruptedAfter: true), SubagentState.stopped);
    expect(of(open, exited: true), SubagentState.stopped);
    expect(of(open, stale: true), SubagentState.stopped);
    final rows = chatRows([
      open,
      ChatItem.fromJson({'kind': 'interrupted', 'uuid': 'i1'}),
    ]);
    expect(rows.last.interruptedAfter, isTrue);
    expect(chatRows([open]).single.interruptedAfter, isFalse);
  });

  testWidgets('subagentRowShowsItsState', (t) async {
    final open = _tool('a1', 'Agent', {'arg': 'title-fetch', 'running': true, 'mark': 'running', 'agentType': 'Explore'});
    await _pump(t, open);
    expect(find.text('◯ running'), findsOneWidget);
    expect(find.text('Explore'), findsOneWidget);
    expect(find.text('title-fetch'), findsOneWidget);
    await _pumpRow(
      t,
      chatRows([
        open,
        ChatItem.fromJson({'kind': 'interrupted', 'uuid': 'i1'}),
      ]).last,
    );
    expect(find.text('stopped'), findsOneWidget);
    await _pumpRow(t, chatRows([open]).single, exited: true);
    expect(find.text('stopped'), findsOneWidget);
    await _pump(t, _tool('a2', 'Agent', {'arg': 'title-fetch', 'mark': 'done'}));
    expect(find.text('✓ done'), findsOneWidget);
    await _pump(
      t,
      _tool('a3', 'Agent', {'arg': 'review', 'mark': 'done', 'agentName': 'alice', 'agentColor': 'blue', 'agentType': 'worker'}),
    );
    expect(_color(t, 'alice'), tintColor('blue'));
    expect(find.text('worker'), findsOneWidget);
  });
}
