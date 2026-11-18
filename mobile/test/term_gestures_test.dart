import 'package:elis_mobile/terminal/term_gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _view = Size(300, 400);
const _row = 20.0;

class _Box {
  _Box(this.t);
  final WidgetTester t;
  final rows = <int>[];

  Future<void> pump({Size content = const Size(300, 400), Key key = const Key('g')}) => t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox.fromSize(
            size: _view,
            child: TermGestures(key: key, content: content, rowHeight: _row, onScroll: rows.add, child: const SizedBox.expand(key: Key('content'))),
          ),
        ),
      ));

  RenderBox get _content => t.renderObject<RenderBox>(find.byKey(const Key('content')));
  Offset global(Offset p) => _content.localToGlobal(p);
  Offset local(Offset p) => _content.globalToLocal(p);
  double get scale => t.widget<Transform>(find.descendant(of: find.byType(TermGestures), matching: find.byType(Transform))).transform.getMaxScaleOnAxis();

  /// [kick] moves the first finger out past the recognizer's slop first (negative: in); the scale counts from there.
  Future<void> pinch(Offset a, Offset b, Offset da, Offset db, {double kick = 25}) async {
    final g1 = await t.startGesture(a, pointer: 1);
    final g2 = await t.startGesture(b, pointer: 2);
    await g1.moveBy(Offset(-kick, 0));
    await t.pump();
    for (var i = 1; i <= 4; i++) {
      await g1.moveBy(da / 4);
      await g2.moveBy(db / 4);
      await t.pump();
    }
    await g1.up();
    await g2.up();
    await t.pump(const Duration(milliseconds: 400));
  }

  Future<void> drag(double dy) async {
    final g = await t.startGesture(const Offset(150, 200));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(Offset(0, dy / 4));
      await t.pump();
    }
    await g.up();
    await t.pump(const Duration(milliseconds: 400));
  }

  /// Fingers 125 apart once past the slop, spread to 250: twice the size, around (137.5, 200).
  Future<void> zoom2x() => pinch(const Offset(100, 200), const Offset(200, 200), const Offset(-62.5, 0), const Offset(62.5, 0));
}

void main() {
  testWidgets('oneFingerDragReportsRows', (t) async {
    final b = _Box(t);
    await b.pump();
    await b.drag(3.5 * _row);
    expect(b.rows.fold<int>(0, (a, r) => a + r), 3);
    await b.drag(2.5 * _row); // with the half row left over: three more
    expect(b.rows.fold<int>(0, (a, r) => a + r), 6);
    await b.drag(-2 * _row);
    expect(b.rows.fold<int>(0, (a, r) => a + r), 4);
    expect(b.scale, 1);
  });

  testWidgets('pinchZoomsAroundTheFocalPoint', (t) async {
    final b = _Box(t);
    await b.pump();
    final under = b.local(const Offset(137.5, 200));
    await b.zoom2x();
    expect(b.scale, closeTo(2, 0.01));
    final now = b.global(under);
    expect(now.dx, closeTo(137.5, 0.5));
    expect(now.dy, closeTo(200, 0.5));
    expect(b.rows, isEmpty);
  });

  testWidgets('scaleIsClamped', (t) async {
    final b = _Box(t);
    await b.pump();
    await b.pinch(const Offset(140, 200), const Offset(160, 200), const Offset(-200, 0), const Offset(200, 0)); // 7.7x asked
    expect(b.scale, 6);
    await b.pinch(const Offset(20, 200), const Offset(280, 200), const Offset(100, 0), const Offset(-100, 0), kick: -25);
    expect(b.scale, 1);
  });

  testWidgets('panStaysInsideTheContent', (t) async {
    final b = _Box(t);
    await b.pump();
    await b.zoom2x();
    await b.pinch(const Offset(100, 100), const Offset(200, 100), const Offset(500, 500), const Offset(500, 500));
    expect(b.global(Offset.zero), Offset.zero); // the top left corner, no further
    await b.pinch(const Offset(100, 300), const Offset(200, 300), const Offset(-500, -500), const Offset(-500, -500));
    expect(b.global(const Offset(300, 400)), const Offset(300, 400));
    expect(b.rows, isEmpty);
  });

  testWidgets('aLiftedFingerAfterAPinchDoesNotScroll', (t) async {
    final b = _Box(t);
    await b.pump();
    final g1 = await t.startGesture(const Offset(100, 200), pointer: 1);
    final g2 = await t.startGesture(const Offset(200, 200), pointer: 2);
    for (var i = 0; i < 4; i++) {
      await g1.moveBy(const Offset(-10, 0));
      await g2.moveBy(const Offset(10, 0));
      await t.pump();
    }
    await g2.up();
    for (var i = 0; i < 4; i++) {
      await g1.moveBy(const Offset(0, 2 * _row));
      await t.pump();
    }
    await g1.up();
    await t.pump();
    expect(b.rows, isEmpty);
    await b.drag(2.5 * _row * b.scale); // a new gesture scrolls again
    expect(b.rows.fold<int>(0, (a, r) => a + r), 2);
  });

  testWidgets('doubleTapResets', (t) async {
    final b = _Box(t);
    await b.pump();
    await b.zoom2x();
    expect(b.scale, greaterThan(1));
    await t.tapAt(const Offset(150, 200));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(const Offset(150, 200));
    await t.pump(const Duration(milliseconds: 400));
    expect(b.scale, 1);
    expect(b.global(const Offset(300, 400)), const Offset(300, 400));
  });

  testWidgets('doubleTapOnATallGridReturnsToTheBottom', (t) async {
    final b = _Box(t);
    await b.pump(content: const Size(300, 1000));
    await b.zoom2x();
    await b.pinch(const Offset(100, 100), const Offset(200, 100), const Offset(0, 2000), const Offset(0, 2000));
    expect(b.global(Offset.zero).dy, 0); // panned to the top
    await t.tapAt(const Offset(150, 200));
    await t.pump(const Duration(milliseconds: 50));
    await t.tapAt(const Offset(150, 200));
    await t.pump(const Duration(milliseconds: 400));
    expect(b.scale, 1);
    expect(b.global(const Offset(0, 1000)), const Offset(0, 400));
  });

  testWidgets('zoomedDragStillScrollsByRows', (t) async {
    final b = _Box(t);
    await b.pump();
    await b.zoom2x();
    await b.drag(3 * _row * 2);
    expect(b.rows.fold<int>(0, (a, r) => a + r), 3);
  });

  testWidgets('tallGridShowsItsBottomRows', (t) async {
    final b = _Box(t);
    await b.pump(content: const Size(300, 1000));
    expect(b.global(const Offset(0, 1000)), const Offset(0, 400));
    await b.pump(content: const Size(300, 1200)); // more rows: still the bottom ones
    expect(b.global(const Offset(0, 1200)), const Offset(0, 400));
    await b.pump(content: const Size(300, 100)); // a short grid sits at the bottom, as the reversed scroll view put it
    expect(b.global(const Offset(0, 100)), const Offset(0, 400));
  });
}
