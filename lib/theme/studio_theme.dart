// ============================================================================
// studio_theme.dart — All 6 Studio Skins ported 1:1 from Audio Engine V10
// ============================================================================

import 'package:material_ui/material_ui.dart';

enum StudioThemeMode {
  darkElegance,
  frostLight,
  cyberpunkNeon,
  warmVintage,
  matrixEmerald,
  tokyoNight,
}

class StudioSkin {
  final StudioThemeMode mode;
  final String name;
  final Color panelBg;
  final Color cardBg;
  final Color btnBg;
  final Color border;
  final Color accent;
  final Color accentFg;
  final Color textMain;
  final Color textMuted;
  final Color specLow;
  final Color specHigh;
  final Color specSlot;

  const StudioSkin({
    required this.mode,
    required this.name,
    required this.panelBg,
    required this.cardBg,
    required this.btnBg,
    required this.border,
    required this.accent,
    required this.accentFg,
    required this.textMain,
    required this.textMuted,
    required this.specLow,
    required this.specHigh,
    required this.specSlot,
  });

  bool get isDark => mode != StudioThemeMode.frostLight;

  Color get selectedRowBg =>
      isDark ? accent.withValues(alpha: 0.32) : const Color(0xFF5B8DC4);

  /// Interpolates the spectrum bar color for bar `index` out of `total`.
  Color barColor(int index, int total) {
    final t = total <= 1 ? 0.0 : (index / (total - 1)).clamp(0.0, 1.0);
    return Color.lerp(specLow, specHigh, t) ?? specLow;
  }

  static StudioSkin fromMode(StudioThemeMode mode) {
    switch (mode) {
      case StudioThemeMode.darkElegance:
        return const StudioSkin(
          mode: StudioThemeMode.darkElegance,
          name: 'Dark Elegance',
          panelBg: Color(0xFF121826),
          cardBg: Color(0xFF1A2334),
          btnBg: Color(0xFF243046),
          border: Color(0xFF303F5A),
          accent: Color(0xFF38BDF8),
          accentFg: Color(0xFF0C121E),
          textMain: Color(0xFFF1F5F9),
          textMuted: Color(0xFF94A3B8),
          specLow: Color(0xFF23A5F5),
          specHigh: Color(0xFFB44BEB),
          specSlot: Color(0xFF263248),
        );
      case StudioThemeMode.frostLight:
        return const StudioSkin(
          mode: StudioThemeMode.frostLight,
          name: 'Frost Light',
          panelBg: Color(0xFFECF0F5),
          cardBg: Color(0xFFFFFFFF),
          btnBg: Color(0xFFE2E8F0),
          border: Color(0xFFCBD5E1),
          accent: Color(0xFF2563EB),
          accentFg: Color(0xFFFFFFFF),
          textMain: Color(0xFF0F172A),
          textMuted: Color(0xFF64748B),
          specLow: Color(0xFF2563EB),
          specHigh: Color(0xFF7C3AED),
          specSlot: Color(0xFFE2E8F0),
        );
      case StudioThemeMode.cyberpunkNeon:
        return const StudioSkin(
          mode: StudioThemeMode.cyberpunkNeon,
          name: 'Cyberpunk Neon',
          panelBg: Color(0xFF0B0B14),
          cardBg: Color(0xFF141224),
          btnBg: Color(0xFF201A38),
          border: Color(0xFF3A2A60),
          accent: Color(0xFF00F0FF),
          accentFg: Color(0xFF0A0A12),
          textMain: Color(0xFFFAFAFF),
          textMuted: Color(0xFFD946EF),
          specLow: Color(0xFF00F5FF),
          specHigh: Color(0xFFFF14B4),
          specSlot: Color(0xFF221C3A),
        );
      case StudioThemeMode.warmVintage:
        return const StudioSkin(
          mode: StudioThemeMode.warmVintage,
          name: 'Warm Vintage Studio',
          panelBg: Color(0xFF1C1612),
          cardBg: Color(0xFF281F19),
          btnBg: Color(0xFF3A2D24),
          border: Color(0xFF544134),
          accent: Color(0xFFF59E0B),
          accentFg: Color(0xFF18100A),
          textMain: Color(0xFFFEF3C7),
          textMuted: Color(0xFFC4A07E),
          specLow: Color(0xFFF59E0B),
          specHigh: Color(0xFFEF4444),
          specSlot: Color(0xFF3A2D24),
        );
      case StudioThemeMode.matrixEmerald:
        return const StudioSkin(
          mode: StudioThemeMode.matrixEmerald,
          name: 'Matrix Emerald',
          panelBg: Color(0xFF0A120E),
          cardBg: Color(0xFF101D16),
          btnBg: Color(0xFF182C22),
          border: Color(0xFF264838),
          accent: Color(0xFF10B981),
          accentFg: Color(0xFF08100C),
          textMain: Color(0xFFDCFCE7),
          textMuted: Color(0xFF6EE7B7),
          specLow: Color(0xFF10B981),
          specHigh: Color(0xFFA3E635),
          specSlot: Color(0xFF182C22),
        );
      case StudioThemeMode.tokyoNight:
        return const StudioSkin(
          mode: StudioThemeMode.tokyoNight,
          name: 'Tokyo Night',
          panelBg: Color(0xFF1A1B26),
          cardBg: Color(0xFF24283B),
          btnBg: Color(0xFF343B58),
          border: Color(0xFF414868),
          accent: Color(0xFF7AA2F7),
          accentFg: Color(0xFF16161E),
          textMain: Color(0xFFC0CAF5),
          textMuted: Color(0xFFA9B1D6),
          specLow: Color(0xFF7AA2F7),
          specHigh: Color(0xFFBB9AF7),
          specSlot: Color(0xFF2C314A),
        );
    }
  }

  ThemeData toThemeData() {
    final brightness = isDark ? Brightness.dark : Brightness.light;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      scaffoldBackgroundColor: panelBg,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: accent,
        onPrimary: accentFg,
        secondary: specHigh,
        onSecondary: Colors.white,
        error: const Color(0xFFEF4444),
        onError: Colors.white,
        surface: cardBg,
        onSurface: textMain,
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: textMain.withValues(alpha: 0.90),
        inactiveTrackColor: btnBg,
        thumbColor: textMain,
        overlayColor: accent.withValues(alpha: 0.22),
        trackHeight: 4.0,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7.5),
      ),
    );
  }
}
