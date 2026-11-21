// ============================================================================
// spectrum_visualizer.dart — 64-Band Logarithmic RTA with White Peak-Hold Caps
// Matches Audio Engine V10 — Audiophile Studio visual style 1:1
// ============================================================================

import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../theme/studio_theme.dart';

class SpectrumVisualizer extends StatelessWidget {
  final StudioSkin skin;
  final Float32List bars;
  final Float32List peaks;
  final int repaintTick;

  const SpectrumVisualizer({
    super.key,
    required this.skin,
    required this.bars,
    required this.peaks,
    required this.repaintTick,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            'Live Spectrum Visualizer',
            style: TextStyle(
              color: skin.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ),
        Container(
          height: 112,
          width: double.infinity,
          decoration: BoxDecoration(
            color: skin.cardBg,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: skin.border.withValues(alpha: 0.7), width: 1),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _RtaPainter(
                skin: skin,
                bars: bars,
                peaks: peaks,
                tick: repaintTick,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '64-Band Logarithmic RTA • 32-Bit Float DSP • TPDF Dither & Peak Limiter',
          style: TextStyle(
            color: skin.textMuted,
            fontSize: 11.5,
            fontWeight: FontWeight.w500,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _RtaPainter extends CustomPainter {
  final StudioSkin skin;
  final Float32List bars;
  final Float32List peaks;
  final int tick;

  _RtaPainter({
    required this.skin,
    required this.bars,
    required this.peaks,
    required this.tick,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final count = bars.length;
    if (count == 0 || size.width <= 0 || size.height <= 0) return;

    final step = size.width / count;
    final barW = (step * 0.66).clamp(1.8, 12.0);
    final padX = (step - barW) * 0.5;
    final radius = Radius.circular((barW * 0.42).clamp(1.0, 3.0));

    final slotPaint = Paint()..color = skin.specSlot;
    final barPaint = Paint();
    final peakPaint = Paint()
      ..color = skin.isDark ? Colors.white.withValues(alpha: 0.92) : skin.textMain;

    const minBaseH = 3.0;

    for (int i = 0; i < count; i++) {
      final x = i * step + padX;

      // Full-height dark recessed slot pillar
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, 0, barW, size.height),
          radius,
        ),
        slotPaint,
      );

      final level = bars[i].clamp(0.0, 1.0);
      final peak = peaks[i].clamp(0.0, 1.0);
      final barColor = skin.barColor(i, count);
      barPaint.color = barColor;

      // Active bar (always keeps a subtle colored baseline cap just like gtkplayer)
      final activeH = (level * size.height).clamp(minBaseH, size.height);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, size.height - activeH, barW, activeH),
          radius,
        ),
        barPaint,
      );

      // Crisp floating white peak-hold cap when peak is above floor
      if (peak > 0.03) {
        final peakY = (size.height - peak * size.height).clamp(0.0, size.height - 2.5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, peakY, barW, 2.4),
            const Radius.circular(1.0),
          ),
          peakPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _RtaPainter oldDelegate) =>
      oldDelegate.tick != tick || oldDelegate.skin.mode != skin.mode;
}
