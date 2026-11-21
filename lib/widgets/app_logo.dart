// ============================================================================
// app_logo.dart — Custom Spectrum Bars App Icon Badge (Audio Engine V10)
// ============================================================================

import 'package:material_ui/material_ui.dart';

import '../theme/studio_theme.dart';

class AudioEngineLogo extends StatelessWidget {
  final StudioSkin skin;
  final double size;

  const AudioEngineLogo({
    super.key,
    required this.skin,
    this.size = 28,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: skin.panelBg,
        borderRadius: BorderRadius.circular(size * 0.24),
        border: Border.all(color: skin.border, width: 1.2),
      ),
      padding: EdgeInsets.all(size * 0.16),
      child: CustomPaint(
        painter: _LogoPainter(skin),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  final StudioSkin skin;
  static const List<double> _heights = [0.42, 0.85, 0.62, 1.0, 0.72, 0.48];

  _LogoPainter(this.skin);

  @override
  void paint(Canvas canvas, Size size) {
    final n = _heights.length;
    final gap = size.width * 0.06;
    final barW = (size.width - gap * (n - 1)) / n;

    for (int i = 0; i < n; i++) {
      final h = size.height * _heights[i];
      final x = i * (barW + gap);
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - h, barW, h),
        Radius.circular(barW * 0.45),
      );
      final paint = Paint()..color = skin.barColor(i, n);
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) =>
      oldDelegate.skin.mode != skin.mode;
}
