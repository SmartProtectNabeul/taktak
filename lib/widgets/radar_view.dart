import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';

class RadarView extends StatefulWidget {
  const RadarView({super.key, required this.devices});

  final List<Device> devices;

  @override
  State<RadarView> createState() => _RadarViewState();
}

class _RadarViewState extends State<RadarView> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: const Duration(seconds: 4))..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) => CustomPaint(
        size: const Size(460, 460),
        painter: RadarPainter(
          sweepAngle: _controller.value * 2 * math.pi,
          devices: widget.devices,
        ),
      ),
    );
  }
}

class RadarPainter extends CustomPainter {
  RadarPainter({required this.sweepAngle, required this.devices});

  final double sweepAngle;
  final List<Device> devices;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width / 2, size.height / 2);

    final circleStroke = Paint()
      ..color = const Color(0xFF66FCF1).withValues(alpha: 0.22)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawCircle(center, radius, circleStroke);
    canvas.drawCircle(center, radius * 0.66, circleStroke);
    canvas.drawCircle(center, radius * 0.33, circleStroke);

    final sweepGradient = SweepGradient(
      colors: [
        const Color(0xFF66FCF1).withValues(alpha: 0.0),
        const Color(0xFF66FCF1).withValues(alpha: 0.5),
        const Color(0xFF66FCF1).withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 0.51],
      transform: GradientRotation(sweepAngle - math.pi / 2),
    );

    final sweepPaint = Paint()
      ..shader = sweepGradient.createShader(Rect.fromCircle(center: center, radius: radius))
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, sweepPaint);

    final accent = Paint()..color = const Color(0xFF66FCF1);

    final textPainter = TextPainter(textDirection: TextDirection.ltr);

    for (var i = 0; i < devices.length; i++) {
      final device = devices[i];
      final angle = (i * 137.5) * math.pi / 180;
      final dRadius = radius * device.distance;
      final pos = Offset(
        center.dx + dRadius * math.cos(angle),
        center.dy + dRadius * math.sin(angle),
      );

      final angleDiff = (angle - (sweepAngle - math.pi / 2)) % (2 * math.pi);
      final isHighlighted = angleDiff < 0.2 || angleDiff > (2 * math.pi - 0.2);

      canvas.drawCircle(
        pos,
        isHighlighted ? 8 : 6,
        Paint()..color = isHighlighted ? Colors.white : const Color(0xFF66FCF1),
      );

      textPainter.text = TextSpan(
        text: device.name,
        style: const TextStyle(color: Colors.white70, fontSize: 12),
      );
      textPainter.layout();
      textPainter.paint(canvas, pos + const Offset(12, -6));
    }

    canvas.drawCircle(center, 11, accent..style = PaintingStyle.fill);
  }

  @override
  bool shouldRepaint(covariant RadarPainter oldDelegate) {
    return sweepAngle != oldDelegate.sweepAngle || devices.length != oldDelegate.devices.length;
  }
}
