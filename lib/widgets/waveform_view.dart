import 'dart:math' as math;

import 'package:flutter/material.dart';

class WaveformView extends StatefulWidget {
  final List<double> peaks;
  final double duration;
  final double selStart;
  final double selEnd;
  final double playhead;
  final void Function(double start, double end) onSelection;
  final void Function(double seconds) onSeek;

  const WaveformView({
    super.key,
    required this.peaks,
    required this.duration,
    required this.selStart,
    required this.selEnd,
    required this.playhead,
    required this.onSelection,
    required this.onSeek,
  });

  @override
  State<WaveformView> createState() => _WaveformViewState();
}

class _WaveformViewState extends State<WaveformView> {
  _DragMode _mode = _DragMode.none;
  double _anchor = 0;
  static const double _handleZone = 28;

  double _xToTime(double x, double width) {
    final dur = widget.duration <= 0 ? 1.0 : widget.duration;
    if (width <= 0) return 0;
    return (x / width * dur).clamp(0.0, dur);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final width = constraints.maxWidth;
      final dur = widget.duration <= 0 ? 1.0 : widget.duration;
      final sx = widget.selStart / dur * width;
      final ex = widget.selEnd / dur * width;

      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => widget.onSeek(_xToTime(d.localPosition.dx, width)),
        onHorizontalDragStart: (d) {
          final x = d.localPosition.dx;
          // 抓哪根线，就只动那根线；抓选区中间，整体平移；抓空白，重新拉选区
          final dStart = (x - sx).abs();
          final dEnd = (x - ex).abs();
          if (dStart < _handleZone && dStart <= dEnd) {
            _mode = _DragMode.startEdge;
            _anchor = widget.selEnd;
          } else if (dEnd < _handleZone) {
            _mode = _DragMode.endEdge;
            _anchor = widget.selStart;
          } else if (x > sx && x < ex) {
            _mode = _DragMode.moveAll;
            _anchor = _xToTime(x, width);
          } else {
            _mode = _DragMode.newSelection;
            final t = _xToTime(x, width);
            _anchor = t;
            widget.onSelection(t, t);
          }
        },
        onHorizontalDragUpdate: (d) {
          final t = _xToTime(d.localPosition.dx, width);
          switch (_mode) {
            case _DragMode.startEdge:
              widget.onSelection(t.clamp(0.0, math.max(0, _anchor - 0.02)), _anchor);
              break;
            case _DragMode.endEdge:
              widget.onSelection(_anchor, t.clamp(math.min(_anchor + 0.02, dur), dur));
              break;
            case _DragMode.moveAll:
              final delta = t - _anchor;
              final len = widget.selEnd - widget.selStart;
              double ns = widget.selStart + delta;
              ns = ns.clamp(0.0, math.max(0.0, dur - len));
              widget.onSelection(ns, ns + len);
              _anchor = t;
              break;
            case _DragMode.newSelection:
              widget.onSelection(math.min(_anchor, t), math.max(_anchor, t));
              break;
            case _DragMode.none:
              break;
          }
        },
        onHorizontalDragEnd: (_) => _mode = _DragMode.none,
        child: CustomPaint(
          painter: _WavePainter(
            peaks: widget.peaks,
            duration: dur,
            selStart: widget.selStart,
            selEnd: widget.selEnd,
            playhead: widget.playhead,
          ),
          child: const SizedBox(height: 168, width: double.infinity),
        ),
      );
    });
  }
}

enum _DragMode { none, startEdge, endEdge, moveAll, newSelection }

class _WavePainter extends CustomPainter {
  final List<double> peaks;
  final double duration;
  final double selStart;
  final double selEnd;
  final double playhead;

  _WavePainter({
    required this.peaks,
    required this.duration,
    required this.selStart,
    required this.selEnd,
    required this.playhead,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFF10161D);
    canvas.drawRRect(RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(12)), bg);

    final mid = size.height / 2;
    final barCount = math.min(peaks.length, size.width.floor());
    if (peaks.isEmpty) {
      final tp = TextPainter(
        text: const TextSpan(text: '波形生成中…', style: TextStyle(color: Colors.white38, fontSize: 13)),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(size.width / 2 - tp.width / 2, mid - tp.height / 2));
      return;
    }

    // 选区底色
    if (selEnd > selStart && duration > 0) {
      final x0 = selStart / duration * size.width;
      final x1 = selEnd / duration * size.width;
      canvas.drawRect(
        Rect.fromLTRB(x0, 0, x1, size.height),
        Paint()..color = const Color(0x3322D3EE),
      );
      final edge = Paint()..color = const Color(0xFF22D3EE)..strokeWidth = 2;
      canvas.drawLine(Offset(x0, 0), Offset(x0, size.height), edge);
      canvas.drawLine(Offset(x1, 0), Offset(x1, size.height), edge);
    }

    final barW = size.width / barCount;
    final paint = Paint()..color = const Color(0xFF7DD3FC);
    for (int i = 0; i < barCount; i++) {
      final v = peaks[(i * peaks.length / barCount).floor()];
      final h = math.max(2.0, v * (size.height * 0.86));
      canvas.drawRect(
        Rect.fromLTWH(i * barW, mid - h / 2, math.max(1.0, barW - 0.6), h),
        paint,
      );
    }

    // 中线
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()..color = Colors.white10,
    );

    if (duration > 0 && playhead > 0) {
      final px = playhead / duration * size.width;
      canvas.drawLine(
        Offset(px, 0),
        Offset(px, size.height),
        Paint()
          ..color = const Color(0xFFFFB74D)
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.selStart != selStart ||
      old.selEnd != selEnd ||
      old.playhead != playhead ||
      old.peaks.length != peaks.length;
}
