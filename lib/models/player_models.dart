// ============================================================================
// player_models.dart — Tracks, Presets, EQ Frequencies & Persistent Config
// ============================================================================

import 'dart:convert';
import 'dart:io';

import '../theme/studio_theme.dart';

const List<int> eqFrequenciesHz = [
  29,
  59,
  119,
  237,
  474,
  947,
  1889,
  3770,
  7523,
  15011,
];

String formatEqFreq(int hz) {
  if (hz >= 1000) {
    return '${(hz / 1000.0).toStringAsFixed(1)}k';
  }
  return '${hz}Hz';
}

enum EqPreset {
  flat,
  warmVintage,
  modernClean,
  bassBoosted,
  vocalEnhance,
  clubMaster,
}

extension EqPresetInfo on EqPreset {
  String get label {
    switch (this) {
      case EqPreset.flat:
        return 'Flat (Normal)';
      case EqPreset.warmVintage:
        return 'Warm Vintage';
      case EqPreset.modernClean:
        return 'Modern Clean';
      case EqPreset.bassBoosted:
        return 'Bass Boosted';
      case EqPreset.vocalEnhance:
        return 'Vocal Enhancer';
      case EqPreset.clubMaster:
        return 'Club Master';
    }
  }

  List<double> get gains {
    switch (this) {
      case EqPreset.flat:
        return [0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0];
      case EqPreset.warmVintage:
        return [2.0, 2.5, 1.5, 0.5, 0.0, 0.0, 0.0, -0.5, -1.0, -1.5];
      case EqPreset.modernClean:
        return [1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.5, 1.0];
      case EqPreset.bassBoosted:
        return [6.8, 5.2, 2.8, 1.5, 0.5, 0.0, 0.0, 0.0, 0.0, 0.0];
      case EqPreset.vocalEnhance:
        return [0.0, 0.0, 0.0, -1.0, 1.0, 2.5, 2.0, 1.5, 0.0, 0.0];
      case EqPreset.clubMaster:
        return [7.65, 5.85, 3.15, 2.0, 1.0, 0.0, 0.0, 2.0, 2.5, 0.0];
    }
  }
}

class TrackItem {
  final String uri;
  final String path;
  String title;
  String artist;
  final String ext;

  TrackItem({
    required this.uri,
    required this.path,
    required this.title,
    this.artist = '',
    this.ext = '',
  });

  String get uniqueKey => uri.isNotEmpty ? uri : path;

  Map<String, dynamic> toJson() => {
    'uri': uri,
    'path': path,
    'title': title,
    'artist': artist,
    'ext': ext,
  };

  factory TrackItem.fromJson(Map<String, dynamic> j) => TrackItem(
    uri: (j['uri'] as String?) ?? '',
    path: (j['path'] as String?) ?? '',
    title: (j['title'] as String?) ?? 'Track',
    artist: (j['artist'] as String?) ?? '',
    ext: (j['ext'] as String?) ?? '',
  );
}

class AudioFolder {
  final String path;
  final String name;
  final int count;

  const AudioFolder({
    required this.path,
    required this.name,
    required this.count,
  });
}

class PlayerConfig {
  StudioThemeMode theme;
  int volumePct;
  int balancePct;
  bool autoHeadroom;
  bool showSpectrum;
  int stereoWidthPct;
  bool punchEnabled;
  int roomReverbPct;
  List<double> eqBands;
  List<TrackItem> playlist;
  int? currentIdx;

  PlayerConfig({
    this.theme = StudioThemeMode.darkElegance,
    this.volumePct = 100,
    this.balancePct = 0,
    this.autoHeadroom = true,
    this.showSpectrum = false,
    this.stereoWidthPct = 0,
    this.punchEnabled = false,
    this.roomReverbPct = 0,
    List<double>? eqBands,
    List<TrackItem>? playlist,
    this.currentIdx,
  }) : eqBands = eqBands ?? List<double>.filled(10, 0.0),
       playlist = playlist ?? <TrackItem>[];

  bool get hasActiveEnhancements =>
      punchEnabled || stereoWidthPct > 0 || roomReverbPct > 0;

  Map<String, dynamic> toJson() => {
    'theme': theme.name,
    'volume_pct': volumePct,
    'balance_pct': balancePct,
    'auto_headroom': autoHeadroom,
    'show_spectrum': showSpectrum,
    'stereo_width_pct': stereoWidthPct,
    'punch_enabled': punchEnabled,
    'room_reverb_pct': roomReverbPct,
    'eq_bands': eqBands,
    'playlist': playlist.map((t) => t.toJson()).toList(),
    'current_idx': currentIdx,
  };

  factory PlayerConfig.fromJson(Map<String, dynamic> j) {
    final themeName = j['theme'] as String?;
    final theme = StudioThemeMode.values.firstWhere(
      (m) => m.name == themeName,
      orElse: () => StudioThemeMode.darkElegance,
    );
    final rawEq = (j['eq_bands'] as List?)?.map((e) => (e as num).toDouble()).toList();
    final eq = (rawEq != null && rawEq.length == 10)
        ? rawEq
        : List<double>.filled(10, 0.0);
    final rawList = (j['playlist'] as List?) ?? const [];
    final playlist = rawList
        .whereType<Map>()
        .map((m) => TrackItem.fromJson(Map<String, dynamic>.from(m)))
        .toList();

    return PlayerConfig(
      theme: theme,
      volumePct: ((j['volume_pct'] as num?)?.toInt() ?? 100).clamp(0, 150),
      balancePct: ((j['balance_pct'] as num?)?.toInt() ?? 0).clamp(-100, 100),
      autoHeadroom: (j['auto_headroom'] as bool?) ?? true,
      showSpectrum: (j['show_spectrum'] as bool?) ?? false,
      stereoWidthPct: ((j['stereo_width_pct'] as num?)?.toInt() ?? 0).clamp(0, 100),
      punchEnabled: (j['punch_enabled'] as bool?) ?? false,
      roomReverbPct: ((j['room_reverb_pct'] as num?)?.toInt() ?? 0).clamp(0, 100),
      eqBands: eq,
      playlist: playlist,
      currentIdx: (j['current_idx'] as num?)?.toInt(),
    );
  }

  static Future<PlayerConfig> loadFromDir(String? dirPath) async {
    if (dirPath == null || dirPath.isEmpty) return PlayerConfig();
    try {
      final file = File('$dirPath/config.json');
      if (await file.exists()) {
        final raw = await file.readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) {
          return PlayerConfig.fromJson(decoded);
        }
      }
    } catch (_) {}
    return PlayerConfig();
  }

  Future<void> saveToDir(String? dirPath) async {
    if (dirPath == null || dirPath.isEmpty) return;
    try {
      final tmp = File('$dirPath/config.json.tmp');
      final dst = File('$dirPath/config.json');
      await tmp.writeAsString(jsonEncode(toJson()));
      await tmp.rename(dst.path);
    } catch (_) {}
  }
}

String formatDuration(double seconds) {
  if (!seconds.isFinite || seconds <= 0) return '0:00';
  final total = seconds.floor();
  final mins = total ~/ 60;
  final secs = total % 60;
  return '$mins:${secs.toString().padLeft(2, '0')}';
}

/// Detects whether a track title begins with Hebrew/Arabic RTL characters.
bool isRtlText(String text) {
  for (final rune in text.runes) {
    if ((rune >= 0x0590 && rune <= 0x05FF) || (rune >= 0x0600 && rune <= 0x06FF)) {
      return true;
    }
    if ((rune >= 0x41 && rune <= 0x5A) || (rune >= 0x61 && rune <= 0x7A)) {
      return false;
    }
  }
  return false;
}
