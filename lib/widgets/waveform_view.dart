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
  double? _dragStart;
  bool _dragging = false;
  static const double _handleZone = 22;

  double _xToTime(double x, double width) {
    final dur = widget.duration <= 0 ? 1.0 : widget.duration;
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
        onTapDown: (d) {
          widget.onSeek(_xToTime(d.localPosition.dx, width));
        },
        onHorizontalDragStart: (d) {
          final x = d.localPosition.dx;
          if ((x - sx).abs() < _handleZone) {
            _dragStart = widget.selEnd;
          } else if ((x - ex).abs() < _handleZone) {
            _dragStart = widget.selStart;
          } else {
            _dragStart = _xToTime(x, width);
            widget.onSelection(_dragStart!, _dragStart!);
          }
          _dragging = true;
          setState(() {});
        },
        onHorizontalDragUpdate: (d) {
          if (!_dragging || _dragStart == null) return;
          final t = _xToTime(d.localPosition.dx, width);
          final a = math.min(_dragStart!, t);
          final b = math.max(_dragStart!, t);
          widget.onSelection(a, b);
        },
        onHorizontalDragEnd: (_) {
          _dragging = false;
        },
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
