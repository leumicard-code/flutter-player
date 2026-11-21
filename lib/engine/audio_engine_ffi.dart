// ============================================================================
// audio_engine_ffi.dart — Dart FFI Bindings to Pure Rust 32-Bit Float Engine
// ============================================================================

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

class TrackMetadata {
  final String? title;
  final String? artist;
  final String? album;
  final int sampleRate;
  final double durationSec;

  const TrackMetadata({
    this.title,
    this.artist,
    this.album,
    this.sampleRate = 48000,
    this.durationSec = 0.0,
  });
}

/// Abstract audio engine interface (implemented by Native FFI & test fallback).
abstract class AudioEngineBridge {
  bool get isNative;

  bool loadFile(String path);
  bool loadFd(int fd, String ext);
  bool play();
  void pause();
  void stop();
  bool isPlaying();
  bool takeEnded();
  double getPosition();
  double getDuration();
  bool seek(double seconds);

  void setVolume(double volume);
  void setMute(bool muted);
  void setBalance(double pan);
  void setEqBand(int band, double gainDb);
  void setAllEqBands(List<double> gains);
  void setAutoHeadroom(bool enabled);
  void setStereoWidening(double amount);
  void setPunchEnabled(bool enabled);
  void setRoomReverb(double amount);
  void resetDspEffects();

  void pollSpectrum(Float32List bars64, Float32List peaks64);
  TrackMetadata getMetadata();
  String getLastError();
  void dispose();
}

// Native C function typedefs
typedef _CreateNative = Pointer<Void> Function();
typedef _CreateDart = Pointer<Void> Function();

typedef _DestroyNative = Void Function(Pointer<Void>);
typedef _DestroyDart = void Function(Pointer<Void>);

typedef _LoadFileNative = Int32 Function(Pointer<Void>, Pointer<Utf8>);
typedef _LoadFileDart = int Function(Pointer<Void>, Pointer<Utf8>);

typedef _LoadFdNative = Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>);
typedef _LoadFdDart = int Function(Pointer<Void>, int, Pointer<Utf8>);

typedef _IntOpNative = Int32 Function(Pointer<Void>);
typedef _IntOpDart = int Function(Pointer<Void>);

typedef _VoidOpNative = Void Function(Pointer<Void>);
typedef _VoidOpDart = void Function(Pointer<Void>);

typedef _DoubleGetNative = Double Function(Pointer<Void>);
typedef _DoubleGetDart = double Function(Pointer<Void>);

typedef _SeekNative = Int32 Function(Pointer<Void>, Double);
typedef _SeekDart = int Function(Pointer<Void>, double);

typedef _SetDoubleNative = Void Function(Pointer<Void>, Double);
typedef _SetDoubleDart = void Function(Pointer<Void>, double);

typedef _SetFloatNative = Void Function(Pointer<Void>, Float);
typedef _SetFloatDart = void Function(Pointer<Void>, double);

typedef _SetIntNative = Void Function(Pointer<Void>, Int32);
typedef _SetIntDart = void Function(Pointer<Void>, int);

typedef _SetEqBandNative = Void Function(Pointer<Void>, Uint32, Double);
typedef _SetEqBandDart = void Function(Pointer<Void>, int, double);

typedef _SetAllEqNative = Void Function(Pointer<Void>, Pointer<Double>);
typedef _SetAllEqDart = void Function(Pointer<Void>, Pointer<Double>);

typedef _PollSpectrumNative = Int32 Function(Pointer<Void>, Pointer<Float>, Pointer<Float>);
typedef _PollSpectrumDart = int Function(Pointer<Void>, Pointer<Float>, Pointer<Float>);

typedef _GetStrNative = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _GetStrDart = int Function(Pointer<Void>, Pointer<Uint8>, int);

class NativeAudioEngine implements AudioEngineBridge {
  final Pointer<Void> _handle;

  final _DestroyDart _destroy;
  final _LoadFileDart _loadFile;
  final _LoadFdDart _loadFd;
  final _IntOpDart _play;
  final _VoidOpDart _pause;
  final _VoidOpDart _stop;
  final _IntOpDart _isPlaying;
  final _IntOpDart _takeEnded;
  final _DoubleGetDart _getPosition;
  final _DoubleGetDart _getDuration;
  final _SeekDart _seek;
  final _SetDoubleDart _setVolume;
  final _SetIntDart _setMute;
  final _SetFloatDart _setBalance;
  final _SetEqBandDart _setEqBand;
  final _SetAllEqDart _setAllEq;
  final _SetIntDart _setAutoHeadroom;
  final _SetFloatDart _setStereoWidening;
  final _SetIntDart _setPunchEnabled;
  final _SetFloatDart _setRoomReverb;
  final _VoidOpDart _resetDspEffects;
  final _PollSpectrumDart _pollSpectrum;
  final _GetStrDart _getMetadataJson;
  final _GetStrDart _getLastError;

  // Reusable zero-GC scratch buffers for 30 FPS spectrum & metadata polling
  final Pointer<Float> _barsBuf = calloc<Float>(64);
  final Pointer<Float> _peaksBuf = calloc<Float>(64);
  final Pointer<Double> _eqBuf = calloc<Double>(10);
  final Pointer<Uint8> _strBuf = calloc<Uint8>(2048);
  bool _disposed = false;

  NativeAudioEngine._(DynamicLibrary lib, this._handle)
    : _destroy = lib.lookupFunction<_DestroyNative, _DestroyDart>('ae_destroy'),
      _loadFile = lib.lookupFunction<_LoadFileNative, _LoadFileDart>('ae_load_file'),
      _loadFd = lib.lookupFunction<_LoadFdNative, _LoadFdDart>('ae_load_fd'),
      _play = lib.lookupFunction<_IntOpNative, _IntOpDart>('ae_play'),
      _pause = lib.lookupFunction<_VoidOpNative, _VoidOpDart>('ae_pause'),
      _stop = lib.lookupFunction<_VoidOpNative, _VoidOpDart>('ae_stop'),
      _isPlaying = lib.lookupFunction<_IntOpNative, _IntOpDart>('ae_is_playing'),
      _takeEnded = lib.lookupFunction<_IntOpNative, _IntOpDart>('ae_take_ended'),
      _getPosition = lib.lookupFunction<_DoubleGetNative, _DoubleGetDart>('ae_get_position'),
      _getDuration = lib.lookupFunction<_DoubleGetNative, _DoubleGetDart>('ae_get_duration'),
      _seek = lib.lookupFunction<_SeekNative, _SeekDart>('ae_seek'),
      _setVolume = lib.lookupFunction<_SetDoubleNative, _SetDoubleDart>('ae_set_volume'),
      _setMute = lib.lookupFunction<_SetIntNative, _SetIntDart>('ae_set_mute'),
      _setBalance = lib.lookupFunction<_SetFloatNative, _SetFloatDart>('ae_set_balance'),
      _setEqBand = lib.lookupFunction<_SetEqBandNative, _SetEqBandDart>('ae_set_eq_band'),
      _setAllEq = lib.lookupFunction<_SetAllEqNative, _SetAllEqDart>('ae_set_all_eq_bands'),
      _setAutoHeadroom = lib.lookupFunction<_SetIntNative, _SetIntDart>('ae_set_auto_headroom'),
      _setStereoWidening = lib.lookupFunction<_SetFloatNative, _SetFloatDart>('ae_set_stereo_widening'),
      _setPunchEnabled = lib.lookupFunction<_SetIntNative, _SetIntDart>('ae_set_punch_enabled'),
      _setRoomReverb = lib.lookupFunction<_SetFloatNative, _SetFloatDart>('ae_set_room_reverb'),
      _resetDspEffects = lib.lookupFunction<_VoidOpNative, _VoidOpDart>('ae_reset_dsp_effects'),
      _pollSpectrum = lib.lookupFunction<_PollSpectrumNative, _PollSpectrumDart>('ae_poll_spectrum'),
      _getMetadataJson = lib.lookupFunction<_GetStrNative, _GetStrDart>('ae_get_metadata_json'),
      _getLastError = lib.lookupFunction<_GetStrNative, _GetStrDart>('ae_get_last_error');

  static AudioEngineBridge create() {
    DynamicLibrary? lib;
    if (Platform.isLinux) {
      // Flutter Linux bundles shared libraries inside `<exe_dir>/lib/`
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      final bundled = '$exeDir/lib/libaudio_engine_v10.so';
      if (File(bundled).existsSync()) {
        try {
          lib = DynamicLibrary.open(bundled);
        } catch (_) {}
      }
    }
    if (lib == null) {
      try {
        lib = DynamicLibrary.open('libaudio_engine_v10.so');
      } catch (_) {}
    }
    if (lib != null) {
      try {
        final createFn = lib.lookupFunction<_CreateNative, _CreateDart>('ae_create');
        final handle = createFn();
        if (handle != nullptr) {
          return NativeAudioEngine._(lib, handle);
        }
      } catch (_) {}
    }
    return StubAudioEngine();
  }

  @override
  bool get isNative => true;

  @override
  bool loadFile(String path) {
    if (_disposed) return false;
    final ptr = path.toNativeUtf8();
    try {
      return _loadFile(_handle, ptr) == 0;
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  bool loadFd(int fd, String ext) {
    if (_disposed || fd < 0) return false;
    final ptr = ext.toNativeUtf8();
    try {
      return _loadFd(_handle, fd, ptr) == 0;
    } finally {
      calloc.free(ptr);
    }
  }

  @override
  bool play() => !_disposed && _play(_handle) == 0;

  @override
  void pause() {
    if (!_disposed) _pause(_handle);
  }

  @override
  void stop() {
    if (!_disposed) _stop(_handle);
  }

  @override
  bool isPlaying() => !_disposed && _isPlaying(_handle) != 0;

  @override
  bool takeEnded() => !_disposed && _takeEnded(_handle) != 0;

  @override
  double getPosition() => _disposed ? 0.0 : _getPosition(_handle);

  @override
  double getDuration() => _disposed ? 0.0 : _getDuration(_handle);

  @override
  bool seek(double seconds) => !_disposed && _seek(_handle, seconds) == 0;

  @override
  void setVolume(double volume) {
    if (!_disposed) _setVolume(_handle, volume);
  }

  @override
  void setMute(bool muted) {
    if (!_disposed) _setMute(_handle, muted ? 1 : 0);
  }

  @override
  void setBalance(double pan) {
    if (!_disposed) _setBalance(_handle, pan);
  }

  @override
  void setEqBand(int band, double gainDb) {
    if (!_disposed) _setEqBand(_handle, band, gainDb);
  }

  @override
  void setAllEqBands(List<double> gains) {
    if (_disposed || gains.length < 10) return;
    for (int i = 0; i < 10; i++) {
      _eqBuf[i] = gains[i];
    }
    _setAllEq(_handle, _eqBuf);
  }

  @override
  void setAutoHeadroom(bool enabled) {
    if (!_disposed) _setAutoHeadroom(_handle, enabled ? 1 : 0);
  }

  @override
  void setStereoWidening(double amount) {
    if (!_disposed) _setStereoWidening(_handle, amount);
  }

  @override
  void setPunchEnabled(bool enabled) {
    if (!_disposed) _setPunchEnabled(_handle, enabled ? 1 : 0);
  }

  @override
  void setRoomReverb(double amount) {
    if (!_disposed) _setRoomReverb(_handle, amount);
  }

  @override
  void resetDspEffects() {
    if (!_disposed) _resetDspEffects(_handle);
  }

  @override
  void pollSpectrum(Float32List bars64, Float32List peaks64) {
    if (_disposed) return;
    final n = _pollSpectrum(_handle, _barsBuf, _peaksBuf);
    if (n == 64) {
      bars64.setAll(0, _barsBuf.asTypedList(64));
      peaks64.setAll(0, _peaksBuf.asTypedList(64));
    }
  }

  @override
  TrackMetadata getMetadata() {
    if (_disposed) return const TrackMetadata();
    final len = _getMetadataJson(_handle, _strBuf, 2048);
    if (len <= 0) return const TrackMetadata();
    try {
      final raw = utf8.decode(_strBuf.asTypedList(len));
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return TrackMetadata(
        title: map['title'] as String?,
        artist: map['artist'] as String?,
        album: map['album'] as String?,
        sampleRate: (map['sample_rate'] as num?)?.toInt() ?? 48000,
        durationSec: (map['duration_sec'] as num?)?.toDouble() ?? 0.0,
      );
    } catch (_) {
      return const TrackMetadata();
    }
  }

  @override
  String getLastError() {
    if (_disposed) return '';
    final len = _getLastError(_handle, _strBuf, 2048);
    if (len <= 0) return '';
    return utf8.decode(_strBuf.asTypedList(len), allowMalformed: true);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _destroy(_handle);
    calloc.free(_barsBuf);
    calloc.free(_peaksBuf);
    calloc.free(_eqBuf);
    calloc.free(_strBuf);
  }
}

/// Safe fallback engine used only in host-side Flutter widget tests.
class StubAudioEngine implements AudioEngineBridge {
  bool _playing = false;

  @override
  bool get isNative => false;

  @override
  bool loadFile(String path) {
    _playing = true;
    return true;
  }

  @override
  bool loadFd(int fd, String ext) {
    _playing = true;
    return true;
  }

  @override
  bool play() {
    _playing = true;
    return true;
  }

  @override
  void pause() => _playing = false;

  @override
  void stop() => _playing = false;

  @override
  bool isPlaying() => _playing;

  @override
  bool takeEnded() => false;

  @override
  double getPosition() => 0.0;

  @override
  double getDuration() => 0.0;

  @override
  bool seek(double seconds) => true;

  @override
  void setVolume(double volume) {}

  @override
  void setMute(bool muted) {}

  @override
  void setBalance(double pan) {}

  @override
  void setEqBand(int band, double gainDb) {}

  @override
  void setAllEqBands(List<double> gains) {}

  @override
  void setAutoHeadroom(bool enabled) {}

  @override
  void setStereoWidening(double amount) {}

  @override
  void setPunchEnabled(bool enabled) {}

  @override
  void setRoomReverb(double amount) {}

  @override
  void resetDspEffects() {}

  @override
  void pollSpectrum(Float32List bars64, Float32List peaks64) {}

  @override
  TrackMetadata getMetadata() => const TrackMetadata();

  @override
  String getLastError() => '';

  @override
  void dispose() {}
}
