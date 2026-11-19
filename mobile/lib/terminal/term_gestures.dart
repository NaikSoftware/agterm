import 'package:flutter/widgets.dart';

/// One finger scrolls the program by rows; two fingers zoom (1x to 6x) around their focal point and pan inside
/// [content]; a double tap resets the zoom; a single tap is [onTap]. At 1x the bottom of [content] is in view.
/// Not an InteractiveViewer, which would take a one-finger drag as a pan.
class TermGestures extends StatefulWidget {
  const TermGestures({
    super.key,
    required this.child,
    required this.content,
    required this.rowHeight,
    required this.onScroll,
    this.onTap,
  });

  final Widget child;

  /// The child's size at 1x.
  final Size content;
  final double rowHeight;

  /// Rows the finger moved, down positive.
  final void Function(int rows) onScroll;

  /// A single tap: not part of a double tap, and no second finger touched.
  final VoidCallback? onTap;

  @override
  State<TermGestures> createState() => _TermGesturesState();
}

class _TermGesturesState extends State<TermGestures> {
  double _scale = 1, _x = 0, _up = 0; // _up: how far the content is panned down from its bottom-aligned place
  double _rows = 0; // the distance in rows not reported yet
  double _startScale = 1;
  Offset _anchor = Offset.zero; // the content point under the fingers when they settled
  bool _pinched = false; // a gesture that had two fingers scrolls nothing until all lift
  int _fingers = 0;
  Offset _last = Offset.zero; // where the scrolling finger was last reported: the recognizer drops its slop
  Size _view = Size.zero;

  Offset get _origin => Offset(_x, _view.height - _scale * widget.content.height + _up);

  // the content stays over the whole view, or bottom left when smaller; called from build, as both sizes change
  void _clamp() {
    final c = widget.content * _scale;
    _x = _x.clamp(-(c.width - _view.width).clamp(0, double.infinity), 0).toDouble();
    _up = _up.clamp(0, (c.height - _view.height).clamp(0, double.infinity)).toDouble();
  }

  void _start(ScaleStartDetails d) {
    _startScale = _scale;
    _anchor = (d.localFocalPoint - _origin) / _scale;
  }

  void _update(ScaleUpdateDetails d) {
    if (d.pointerCount > 1) _pinched = true;
    if (_pinched) {
      if (d.pointerCount < 2) return;
      setState(() {
        _scale = (_startScale * d.scale).clamp(1, 6).toDouble();
        final o = d.localFocalPoint - _anchor * _scale;
        _x = o.dx;
        _up = o.dy - (_view.height - _scale * widget.content.height);
      });
      return;
    }
    _rows += (d.localFocalPoint.dy - _last.dy) / (widget.rowHeight * _scale);
    _last = d.localFocalPoint;
    final n = _rows.truncate();
    if (n == 0) return;
    _rows -= n;
    widget.onScroll(n);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      _view = box.biggest;
      _clamp();
      return Listener(
        onPointerDown: (e) {
          if (_fingers++ > 0) {
            _pinched = true; // also a still second finger, which never reaches onScaleUpdate: not a tap
            return;
          }
          _pinched = false;
          _last = e.localPosition;
        },
        onPointerUp: (_) => _fingers--,
        onPointerCancel: (_) => _fingers--,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _start,
          onScaleUpdate: _update,
          onTap: widget.onTap == null ? null : () => _pinched ? null : widget.onTap!(),
          onDoubleTap: () => setState(() {
            _scale = 1;
            _x = 0;
            _up = 0;
          }),
          child: ClipRect(
            child: OverflowBox(
              alignment: Alignment.topLeft,
              minWidth: widget.content.width,
              maxWidth: widget.content.width,
              minHeight: widget.content.height,
              maxHeight: widget.content.height,
              child: Transform(
                transform: Matrix4.translationValues(_origin.dx, _origin.dy, 0)..scaleByDouble(_scale, _scale, 1, 1),
                child: widget.child,
              ),
            ),
          ),
        ),
      );
    },
  );
}
