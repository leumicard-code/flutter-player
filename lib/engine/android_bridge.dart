// ============================================================================
// android_bridge.dart — Cross-Platform Native Bridge (Android Kotlin + Linux KDE)
// ============================================================================

import 'dart:io';

import 'package:flutter/services.dart';

import '../models/player_models.dart';

const Set<String> _audioExts = {
  'mp3',
  'flac',
  'wav',
  'ogg',
  'm4a',
  'aac',
  'opus',
  'alac',
};

class AndroidBridge {
  static const MethodChannel _ch = MethodChannel('audio_engine_v10/android');

  static bool get _isLinuxDesktop => Platform.isLinux && !Platform.isAndroid;

  static void setMediaActionHandler(void Function(String action) handler) {
    if (_isLinuxDesktop) return;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'onMediaAction' && call.arguments is String) {
        handler(call.arguments as String);
      }
    });
  }

  static Future<String?> getAppDataDir() async {
    if (_isLinuxDesktop) {
      final home = Platform.environment['HOME'];
      if (home == null || home.isEmpty) return null;
      final dir = Directory('$home/.config/audio_engine_v10_flutter');
      try {
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        return dir.path;
      } catch (_) {
        return null;
      }
    }
    try {
      return await _ch.invokeMethod<String>('getAppDataDir');
    } catch (_) {
      return null;
    }
  }

  static Future<bool> requestPermissions() async {
    if (_isLinuxDesktop) return true;
    try {
      return (await _ch.invokeMethod<bool>('requestPermissions')) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<List<AudioFolder>> scanAudioFolders() async {
    if (_isLinuxDesktop) {
      final home = Platform.environment['HOME'] ?? '';
      final candidates = <String>[
        if (home.isNotEmpty) '$home/Music',
        if (home.isNotEmpty) '$home/Downloads',
        if (home.isNotEmpty) '$home/code1/הרצה/downloads',
      ];
      final counts = <String, int>{};
      for (final root in candidates) {
        final d = Directory(root);
        if (!await d.exists()) continue;
        await for (final entity in d.list(recursive: true, followLinks: false)) {
          if (entity is File && _isAudioPath(entity.path)) {
            final parent = entity.parent.path;
            counts[parent] = (counts[parent] ?? 0) + 1;
          }
        }
      }
      final list = counts.entries
          .map((e) => AudioFolder(
                path: e.key,
                name: e.key.split('/').where((s) => s.isNotEmpty).lastOrNull ?? e.key,
                count: e.value,
              ))
          .toList()
        ..sort((a, b) => b.count.compareTo(a.count));
      return list;
    }

    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('scanAudioFolders');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((m) {
        return AudioFolder(
          path: (m['path'] as String?) ?? '',
          name: (m['name'] as String?) ?? 'Folder',
          count: (m['count'] as num?)?.toInt() ?? 0,
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  /// Opens native Linux KDE `kdialog` (or `zenity`) folder picker.
  static Future<String?> pickFolderLinux() async {
    if (!_isLinuxDesktop) return null;
    final home = Platform.environment['HOME'] ?? '/';
    try {
      final res = await Process.run('kdialog', [
        '--getexistingdirectory',
        '$home/Music',
        '--title',
        'Select Music Folder — Audio Engine V10',
      ]);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).trim();
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
    try {
      final res = await Process.run('zenity', [
        '--file-selection',
        '--directory',
        '--title=Select Music Folder',
      ]);
      if (res.exitCode == 0) {
        final out = (res.stdout as String).trim();
        if (out.isNotEmpty) return out;
      }
    } catch (_) {}
    return null;
  }

  static Future<List<TrackItem>> scanDeviceAudio({String? folder}) async {
    if (_isLinuxDesktop) {
      final home = Platform.environment['HOME'] ?? '';
      final roots = (folder != null && folder.isNotEmpty)
          ? <String>[folder]
          : <String>[
              if (home.isNotEmpty) '$home/Music',
              if (home.isNotEmpty) '$home/Downloads',
            ];
      final tracks = <TrackItem>[];
      for (final root in roots) {
        final d = Directory(root);
        if (!await d.exists()) continue;
        final files = <File>[];
        await for (final entity in d.list(recursive: true, followLinks: false)) {
          if (entity is File && _isAudioPath(entity.path)) {
            files.add(entity);
          }
        }
        files.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
        for (final f in files) {
          tracks.add(_trackFromPath(f.path));
        }
      }
      return tracks;
    }

    try {
      final raw = await _ch.invokeMethod<List<dynamic>>(
        'scanDeviceAudio',
        {'folder': folder},
      );
      if (raw == null) return const [];
      return raw.whereType<Map>().map((m) {
        return TrackItem(
          uri: (m['uri'] as String?) ?? '',
          path: (m['path'] as String?) ?? '',
          title: (m['title'] as String?) ?? 'Track',
          artist: (m['artist'] as String?) ?? '',
          ext: (m['ext'] as String?) ?? '',
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<List<TrackItem>> pickAudioFiles() async {
    if (_isLinuxDesktop) {
      final home = Platform.environment['HOME'] ?? '/';
      try {
        final res = await Process.run('kdialog', [
          '--getopenfilename',
          '$home/Music',
          'Audio Files (*.mp3 *.flac *.wav *.ogg *.m4a *.aac *.opus)|All Files (*)',
          '--multiple',
          '--separate-output',
          '--title',
          'Add Audio Files — Audio Engine V10',
        ]);
        if (res.exitCode == 0) {
          final lines = (res.stdout as String)
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && File(s).existsSync());
          return lines.map(_trackFromPath).toList();
        }
      } catch (_) {}
      try {
        final res = await Process.run('zenity', [
          '--file-selection',
          '--multiple',
          '--separator=\n',
          '--title=Add Audio Files',
        ]);
        if (res.exitCode == 0) {
          final lines = (res.stdout as String)
              .split('\n')
              .map((s) => s.trim())
              .where((s) => s.isNotEmpty && File(s).existsSync());
          return lines.map(_trackFromPath).toList();
        }
      } catch (_) {}
      return const [];
    }

    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('pickAudioFiles');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((m) {
        return TrackItem(
          uri: (m['uri'] as String?) ?? '',
          path: (m['path'] as String?) ?? '',
          title: (m['title'] as String?) ?? 'Track',
          artist: (m['artist'] as String?) ?? '',
          ext: (m['ext'] as String?) ?? '',
        );
      }).toList();
    } catch (_) {
      return const [];
    }
  }

  static Future<int> openContentFd(String uri) async {
    if (_isLinuxDesktop) return -1;
    try {
      return (await _ch.invokeMethod<int>('openContentFd', {'uri': uri})) ?? -1;
    } catch (_) {
      return -1;
    }
  }

  static Future<void> updateNotification({
    required String title,
    required String artist,
    required bool playing,
  }) async {
    if (_isLinuxDesktop) return;
    try {
      await _ch.invokeMethod('updateNotification', {
        'title': title,
        'artist': artist,
        'playing': playing,
      });
    } catch (_) {}
  }

  static Future<void> stopNotification() async {
    if (_isLinuxDesktop) return;
    try {
      await _ch.invokeMethod('stopNotification');
    } catch (_) {}
  }

  static bool _isAudioPath(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot + 1 >= path.length) return false;
    return _audioExts.contains(path.substring(dot + 1).toLowerCase());
  }

  static TrackItem _trackFromPath(String path) {
    final name = path.split('/').last;
    final dot = name.lastIndexOf('.');
    final stem = (dot > 0 ? name.substring(0, dot) : name).trim();
    final ext = (dot > 0 && dot + 1 < name.length)
        ? name.substring(dot + 1).toLowerCase()
        : '';
    final sep = stem.indexOf(' - ');
    final title = sep > 0 ? stem.substring(sep + 3).trim() : stem;
    final artist = sep > 0 ? stem.substring(0, sep).trim() : '';
    return TrackItem(
      uri: '',
      path: path,
      title: title.isEmpty ? stem : title,
      artist: artist,
      ext: ext,
    );
  }
}
