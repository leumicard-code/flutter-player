// ============================================================================
// main.dart — Audio Engine V10 — Audiophile Studio (Flutter + Rust F32LE DSP)
// Faithful Android mobile edition of Audio Engine V10 (GTKPlayer)
// ============================================================================

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'engine/android_bridge.dart';
import 'engine/audio_engine_ffi.dart';
import 'models/player_models.dart';
import 'theme/studio_theme.dart';
import 'widgets/app_logo.dart';
import 'widgets/dsp_studio_sheet.dart';
import 'widgets/spectrum_visualizer.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AudioEngineV10App());
}

class AudioEngineV10App extends StatefulWidget {
  final AudioEngineBridge? engineOverride;

  const AudioEngineV10App({super.key, this.engineOverride});

  @override
  State<AudioEngineV10App> createState() => _AudioEngineV10AppState();
}

class _AudioEngineV10AppState extends State<AudioEngineV10App> {
  late final AudioEngineBridge _engine;
  PlayerConfig _cfg = PlayerConfig();
  String? _dataDir;

  // Real-time playback state
  bool _isPlaying = false;
  bool _isMuted = false;
  double _positionSec = 0.0;
  double _durationSec = 0.0;
  bool _isSeeking = false;
  double _seekPreviewSec = 0.0;
  int _sampleRateHz = 48000;

  // Live 64-band RTA spectrum buffers (zero per-frame allocations)
  final Float32List _specBars = Float32List(64);
  final Float32List _specPeaks = Float32List(64);
  int _specTick = 0;

  // Playlist search & scroll
  final TextEditingController _filterCtrl = TextEditingController();
  final ScrollController _listScrollCtrl = ScrollController();
  String _filterQuery = '';

  Timer? _pollTimer;
  Timer? _saveDebounce;

  StudioSkin get _skin => StudioSkin.fromMode(_cfg.theme);

  TrackItem? get _currentTrack {
    final idx = _cfg.currentIdx;
    if (idx == null || idx < 0 || idx >= _cfg.playlist.length) return null;
    return _cfg.playlist[idx];
  }

  @override
  void initState() {
    super.initState();
    _engine = widget.engineOverride ?? NativeAudioEngine.create();
    _applyAllDspToEngine();
    _initAsync();

    AndroidBridge.setMediaActionHandler(_handleMediaAction);

    // ~30 FPS real-time RTA Spectrum + position + EOS polling loop
    _pollTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _onPollTick();
    });
  }

  Future<void> _initAsync() async {
    _dataDir = await AndroidBridge.getAppDataDir();
    final loaded = await PlayerConfig.loadFromDir(_dataDir);
    if (!mounted) return;
    setState(() {
      _cfg = loaded;
    });
    _applyAllDspToEngine();
  }

  void _applyAllDspToEngine() {
    _engine.setAllEqBands(_cfg.eqBands);
    _engine.setAutoHeadroom(_cfg.autoHeadroom);
    _engine.setStereoWidening(_cfg.stereoWidthPct / 100.0);
    _engine.setPunchEnabled(_cfg.punchEnabled);
    _engine.setRoomReverb(_cfg.roomReverbPct / 100.0);
    _engine.setBalance(_cfg.balancePct / 100.0);
    _engine.setVolume(_cfg.volumePct / 100.0);
    _engine.setMute(_isMuted);
  }

  void _scheduleSave() {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 350), () {
      _cfg.saveToDir(_dataDir);
    });
  }

  void _onPollTick() {
    if (!mounted) return;

    final playingNow = _engine.isPlaying();
    bool anyVisual = false;
    if (_cfg.showSpectrum) {
      _engine.pollSpectrum(_specBars, _specPeaks);
      anyVisual = playingNow;
      if (!anyVisual) {
        for (int i = 0; i < 64; i++) {
          if (_specBars[i] > 0.002 || _specPeaks[i] > 0.002) {
            anyVisual = true;
            break;
          }
        }
      }
    }

    if (_engine.takeEnded()) {
      _playNextTrack();
      return;
    }

    final pos = _engine.getPosition();
    final dur = _engine.getDuration();

    if (anyVisual ||
        playingNow != _isPlaying ||
        (pos - _positionSec).abs() > 0.25 ||
        (dur - _durationSec).abs() > 0.15) {
      setState(() {
        _isPlaying = playingNow;
        if (!_isSeeking) _positionSec = pos;
        if (dur > 0) _durationSec = dur;
        if (_cfg.showSpectrum) _specTick++;
      });
    }
  }

  void _handleMediaAction(String action) {
    switch (action) {
      case 'play':
        if (!_isPlaying) _togglePlayPause();
        break;
      case 'pause':
        if (_isPlaying) _togglePlayPause();
        break;
      case 'toggle':
        _togglePlayPause();
        break;
      case 'next':
        _playNextTrack();
        break;
      case 'prev':
        _playPrevTrack();
        break;
      case 'stop':
        _stopPlayback();
        break;
    }
  }

  Future<void> _playTrackAt(int idx, BuildContext? ctx) async {
    if (idx < 0 || idx >= _cfg.playlist.length) return;
    final track = _cfg.playlist[idx];

    bool ok = false;
    // Prefer direct path when readable, fallback to zero-copy SAF content:// fd!
    if (track.path.isNotEmpty && File(track.path).existsSync()) {
      ok = _engine.loadFile(track.path);
    }
    if (!ok && track.uri.isNotEmpty) {
      final fd = await AndroidBridge.openContentFd(track.uri);
      if (fd >= 0) {
        ok = _engine.loadFd(fd, track.ext);
      }
    }

    if (!mounted) return;

    if (ok) {
      final meta = _engine.getMetadata();
      setState(() {
        _cfg.currentIdx = idx;
        if (meta.title != null && meta.title!.trim().isNotEmpty) {
          track.title = meta.title!.trim();
        }
        if (meta.artist != null && meta.artist!.trim().isNotEmpty) {
          track.artist = meta.artist!.trim();
        }
        _sampleRateHz = meta.sampleRate > 0 ? meta.sampleRate : 48000;
        _durationSec = meta.durationSec > 0 ? meta.durationSec : _engine.getDuration();
        _positionSec = 0.0;
        _isPlaying = true;
      });
      _scheduleSave();
      AndroidBridge.updateNotification(
        title: track.title,
        artist: track.artist,
        playing: true,
      );
    } else if (ctx != null && ctx.mounted) {
      final err = _engine.getLastError();
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            err.isNotEmpty ? 'Playback error: $err' : 'Cannot open: ${track.title}',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  void _togglePlayPause([BuildContext? ctx]) {
    if (_isPlaying) {
      _engine.pause();
      setState(() => _isPlaying = false);
      final cur = _currentTrack;
      if (cur != null) {
        AndroidBridge.updateNotification(
          title: cur.title,
          artist: cur.artist,
          playing: false,
        );
      }
    } else {
      if (_cfg.currentIdx != null && _durationSec > 0) {
        _engine.play();
        setState(() => _isPlaying = true);
        final cur = _currentTrack;
        if (cur != null) {
          AndroidBridge.updateNotification(
            title: cur.title,
            artist: cur.artist,
            playing: true,
          );
        }
      } else if (_cfg.playlist.isNotEmpty) {
        _playTrackAt(_cfg.currentIdx ?? 0, ctx);
      }
    }
  }

  void _stopPlayback() {
    _engine.stop();
    setState(() {
      _isPlaying = false;
      _positionSec = 0.0;
    });
    AndroidBridge.stopNotification();
  }

  void _playNextTrack([BuildContext? ctx]) {
    if (_cfg.playlist.isEmpty) return;
    final nextIdx = _cfg.currentIdx == null
        ? 0
        : (_cfg.currentIdx! + 1) % _cfg.playlist.length;
    _playTrackAt(nextIdx, ctx);
  }

  void _playPrevTrack([BuildContext? ctx]) {
    if (_cfg.playlist.isEmpty) return;
    if (_positionSec > 3.5 && _cfg.currentIdx != null) {
      _engine.seek(0.0);
      setState(() => _positionSec = 0.0);
      return;
    }
    final prevIdx = _cfg.currentIdx == null
        ? 0
        : (_cfg.currentIdx! - 1 + _cfg.playlist.length) % _cfg.playlist.length;
    _playTrackAt(prevIdx, ctx);
  }

  void _appendUniqueTracks(List<TrackItem> incoming) {
    if (incoming.isEmpty) return;
    final existing = _cfg.playlist.map((t) => t.uniqueKey).toSet();
    final toAdd = incoming.where((t) => existing.add(t.uniqueKey)).toList();
    if (toAdd.isEmpty) return;
    setState(() {
      _cfg.playlist.addAll(toAdd);
    });
    _scheduleSave();
  }

  Future<void> _onPickFiles(BuildContext ctx) async {
    final picked = await AndroidBridge.pickAudioFiles();
    if (!ctx.mounted) return;
    if (picked.isNotEmpty) {
      final wasEmpty = _cfg.playlist.isEmpty;
      _appendUniqueTracks(picked);
      if (wasEmpty && _cfg.playlist.isNotEmpty) {
        _playTrackAt(0, ctx);
      }
    }
  }

  Future<void> _onOpenFolderPicker(BuildContext ctx) async {
    final granted = await AndroidBridge.requestPermissions();
    if (!ctx.mounted) return;
    if (!granted) {
      ScaffoldMessenger.of(ctx).showSnackBar(
        const SnackBar(
          content: Text('Audio permission is required to scan device music folders.'),
        ),
      );
      return;
    }

    final folders = await AndroidBridge.scanAudioFolders();
    if (!ctx.mounted) return;

    await showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: _skin.panelBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Import Music Library / Folder',
                  style: TextStyle(
                    color: _skin.textMain,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                if (Platform.isLinux && !Platform.isAndroid) ...[
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: BorderSide(color: _skin.accent.withValues(alpha: 0.6)),
                    ),
                    tileColor: _skin.cardBg,
                    leading: Icon(Icons.create_new_folder_rounded, color: _skin.accent),
                    title: Text(
                      'Browse Any Folder...',
                      style: TextStyle(
                        color: _skin.textMain,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    subtitle: Text(
                      'Open KDE/System folder picker',
                      style: TextStyle(color: _skin.textMuted, fontSize: 12),
                    ),
                    onTap: () async {
                      Navigator.pop(sheetCtx);
                      final chosen = await AndroidBridge.pickFolderLinux();
                      if (chosen == null || chosen.isEmpty) return;
                      final tracks = await AndroidBridge.scanDeviceAudio(folder: chosen);
                      if (!ctx.mounted) return;
                      final wasEmpty = _cfg.playlist.isEmpty;
                      _appendUniqueTracks(tracks);
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        SnackBar(content: Text('Loaded ${tracks.length} audio tracks')),
                      );
                      if (wasEmpty && _cfg.playlist.isNotEmpty) {
                        _playTrackAt(0, ctx);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                ],
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                    side: BorderSide(color: _skin.accent.withValues(alpha: 0.6)),
                  ),
                  tileColor: _skin.cardBg,
                  leading: Icon(Icons.library_music_rounded, color: _skin.accent),
                  title: Text(
                    'All Device Music',
                    style: TextStyle(
                      color: _skin.textMain,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    Platform.isLinux && !Platform.isAndroid
                        ? 'Scan ~/Music and ~/Downloads'
                        : 'Scan all audio tracks on this Android device',
                    style: TextStyle(color: _skin.textMuted, fontSize: 12),
                  ),
                  onTap: () async {
                    Navigator.pop(sheetCtx);
                    final all = await AndroidBridge.scanDeviceAudio();
                    if (!ctx.mounted) return;
                    final wasEmpty = _cfg.playlist.isEmpty;
                    _appendUniqueTracks(all);
                    ScaffoldMessenger.of(ctx).showSnackBar(
                      SnackBar(content: Text('Loaded ${all.length} audio tracks')),
                    );
                    if (wasEmpty && _cfg.playlist.isNotEmpty) {
                      _playTrackAt(0, ctx);
                    }
                  },
                ),
                if (folders.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    'Music Folders (${folders.length})',
                    style: TextStyle(
                      color: _skin.accent,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: folders.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 6),
                      itemBuilder: (_, i) {
                        final f = folders[i];
                        return ListTile(
                          dense: true,
                          tileColor: _skin.cardBg,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                            side: BorderSide(color: _skin.border),
                          ),
                          leading: Icon(Icons.folder_rounded, color: _skin.accent),
                          title: Text(
                            f.name,
                            style: TextStyle(
                              color: _skin.textMain,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            f.path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: _skin.textMuted, fontSize: 11),
                          ),
                          trailing: Text(
                            '${f.count}',
                            style: TextStyle(
                              color: _skin.accent,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          onTap: () async {
                            Navigator.pop(sheetCtx);
                            final tracks =
                                await AndroidBridge.scanDeviceAudio(folder: f.path);
                            if (!ctx.mounted) return;
                            final wasEmpty = _cfg.playlist.isEmpty;
                            _appendUniqueTracks(tracks);
                            if (wasEmpty && _cfg.playlist.isNotEmpty) {
                              _playTrackAt(0, ctx);
                            }
                          },
                        );
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  void _clearPlaylist() {
    _stopPlayback();
    setState(() {
      _cfg.playlist.clear();
      _cfg.currentIdx = null;
      _durationSec = 0.0;
    });
    _scheduleSave();
  }

  void _openDspStudio(BuildContext ctx) {
    showModalBottomSheet<void>(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DspStudioSheet(
        skin: _skin,
        config: _cfg,
        onEqBandChanged: (band, gainDb) {
          setState(() => _cfg.eqBands[band] = gainDb);
          _engine.setEqBand(band, gainDb);
          _scheduleSave();
        },
        onPresetSelected: (preset) {
          final gains = List<double>.from(preset.gains);
          setState(() => _cfg.eqBands = gains);
          _engine.setAllEqBands(gains);
          _scheduleSave();
        },
        onAutoHeadroomChanged: (on) {
          setState(() => _cfg.autoHeadroom = on);
          _engine.setAutoHeadroom(on);
          _scheduleSave();
        },
        onStereoWidthChanged: (pct) {
          setState(() => _cfg.stereoWidthPct = pct);
          _engine.setStereoWidening(pct / 100.0);
          _scheduleSave();
        },
        onRoomReverbChanged: (pct) {
          setState(() => _cfg.roomReverbPct = pct);
          _engine.setRoomReverb(pct / 100.0);
          _scheduleSave();
        },
        onBalanceChanged: (pct) {
          setState(() => _cfg.balancePct = pct);
          _engine.setBalance(pct / 100.0);
          _scheduleSave();
        },
        onPunchChanged: (on) {
          setState(() => _cfg.punchEnabled = on);
          _engine.setPunchEnabled(on);
          _scheduleSave();
        },
        onResetDsp: () {
          setState(() {
            _cfg.stereoWidthPct = 0;
            _cfg.roomReverbPct = 0;
            _cfg.balancePct = 0;
            _cfg.punchEnabled = false;
            _cfg.autoHeadroom = true;
          });
          _engine.resetDspEffects();
          _engine.setBalance(0.0);
          _scheduleSave();
        },
      ),
    );
  }

  void _openThemePicker(BuildContext ctx) {
    showModalBottomSheet<void>(
      context: ctx,
      backgroundColor: _skin.panelBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (sheetCtx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Studio Skin / Theme',
                  style: TextStyle(
                    color: _skin.textMain,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 10),
                ...StudioThemeMode.values.map((mode) {
                  final candidate = StudioSkin.fromMode(mode);
                  final selected = mode == _cfg.theme;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 7),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(10),
                      onTap: () {
                        setState(() => _cfg.theme = mode);
                        _scheduleSave();
                        Navigator.pop(sheetCtx);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: candidate.cardBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: selected ? candidate.accent : candidate.border,
                            width: selected ? 1.8 : 1.0,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 24,
                              height: 24,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                gradient: LinearGradient(
                                  colors: [candidate.specLow, candidate.specHigh],
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                candidate.name,
                                style: TextStyle(
                                  color: candidate.textMain,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            if (selected)
                              Icon(Icons.check_circle_rounded, color: candidate.accent),
                          ],
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _saveDebounce?.cancel();
    _filterCtrl.dispose();
    _listScrollCtrl.dispose();
    _engine.dispose();
    super.dispose();
  }

  List<int> _visibleTrackIndices() {
    final q = _filterQuery.trim().toLowerCase();
    final out = <int>[];
    for (int i = 0; i < _cfg.playlist.length; i++) {
      final item = _cfg.playlist[i];
      if (q.isEmpty ||
          item.title.toLowerCase().contains(q) ||
          item.artist.toLowerCase().contains(q)) {
        out.add(i);
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final skin = _skin;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: skin.isDark ? Brightness.light : Brightness.dark,
        systemNavigationBarColor: skin.btnBg,
        systemNavigationBarIconBrightness:
            skin.isDark ? Brightness.light : Brightness.dark,
      ),
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Audio Engine V10 — Audiophile Studio',
      theme: skin.toThemeData(),
      home: Builder(
        builder: (ctx) => _buildScaffold(ctx, skin),
      ),
    );
  }

  Widget _buildScaffold(BuildContext ctx, StudioSkin skin) {
    final cur = _currentTrack;
    final visible = _visibleTrackIndices();
    final effectivePos = _isSeeking ? _seekPreviewSec : _positionSec;
    final sliderMax = _durationSec > 0 ? _durationSec : 1.0;

    final titleText = cur?.title ?? 'Ready to Play — Audio Engine V10';
    final artistText = cur == null
        ? 'Pure 32-Bit Float DSP • Tap 📁 to load music'
        : (cur.artist.isNotEmpty
              ? cur.artist
              : '${(_sampleRateHz / 1000.0).toStringAsFixed(1)} kHz • 32-Bit Float');

    return Scaffold(
      backgroundColor: skin.panelBg,
      body: SafeArea(
        child: Column(
          children: [
            // ================================================================
            // Top Studio Title & Menu Bar
            // ================================================================
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: skin.btnBg,
                border: Border(bottom: BorderSide(color: skin.border, width: 1)),
              ),
              child: Row(
                children: [
                  AudioEngineLogo(skin: skin, size: 28),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Audio Engine V10 — Audiophile Studio',
                      style: TextStyle(
                        color: skin.textMain,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: _cfg.showSpectrum
                        ? 'Hide Live Spectrum (More Playlist Space)'
                        : 'Show Live Spectrum Visualizer',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(
                      Icons.equalizer_rounded,
                      color: _cfg.showSpectrum ? skin.accent : skin.textMuted,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() => _cfg.showSpectrum = !_cfg.showSpectrum);
                      _scheduleSave();
                    },
                  ),
                  IconButton(
                    tooltip: 'Studio Theme',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.palette_outlined, color: skin.accent, size: 20),
                    onPressed: () => _openThemePicker(ctx),
                  ),
                  IconButton(
                    tooltip: 'Equalizer & 32-Bit DSP Studio',
                    visualDensity: VisualDensity.compact,
                    icon: Icon(Icons.tune_rounded, color: skin.accent, size: 21),
                    onPressed: () => _openDspStudio(ctx),
                  ),
                ],
              ),
            ),

            // ================================================================
            // Main Content Body
            // ================================================================
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --------------------------------------------------------
                    // 1. Audio Controller Section
                    // --------------------------------------------------------
                    Text(
                      'Audio Controller',
                      style: TextStyle(
                        color: skin.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        titleText,
                        textDirection: isRtlText(titleText)
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        style: TextStyle(
                          color: skin.textMain,
                          fontSize: 19,
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    SizedBox(
                      width: double.infinity,
                      child: Text(
                        artistText,
                        textDirection: isRtlText(artistText)
                            ? TextDirection.rtl
                            : TextDirection.ltr,
                        style: TextStyle(
                          color: skin.accent,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 6),

                    // Time Readout + Seek Slider
                    Row(
                      children: [
                        Text(
                          '${formatDuration(effectivePos)} / ${formatDuration(_durationSec)}',
                          style: TextStyle(
                            color: skin.textMuted,
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: SizedBox(
                            height: 30,
                            child: SliderTheme(
                              data: Theme.of(ctx).sliderTheme.copyWith(
                                trackHeight: 4.0,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                              ),
                              child: Slider(
                                min: 0.0,
                                max: sliderMax,
                                value: effectivePos.clamp(0.0, sliderMax),
                                onChangeStart: (v) {
                                  setState(() {
                                    _isSeeking = true;
                                    _seekPreviewSec = v;
                                  });
                                },
                                onChanged: (v) {
                                  setState(() => _seekPreviewSec = v);
                                },
                                onChangeEnd: (v) {
                                  _engine.seek(v);
                                  setState(() {
                                    _isSeeking = false;
                                    _positionSec = v;
                                  });
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),

                    // Transport Buttons Row (matching screenshot layout!)
                    Row(
                      children: [
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.skip_previous_rounded,
                          size: 40,
                          onTap: () => _playPrevTrack(ctx),
                        ),
                        const SizedBox(width: 10),
                        _CircleControlButton(
                          skin: skin,
                          icon: _isPlaying
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 50,
                          primary: true,
                          onTap: () => _togglePlayPause(ctx),
                        ),
                        const SizedBox(width: 10),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.skip_next_rounded,
                          size: 40,
                          onTap: () => _playNextTrack(ctx),
                        ),
                        const SizedBox(width: 10),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.stop_rounded,
                          size: 40,
                          onTap: _stopPlayback,
                        ),
                        const SizedBox(width: 10),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.tune_rounded,
                          size: 42,
                          accentOutline: true,
                          highlighted: _cfg.hasActiveEnhancements,
                          onTap: () => _openDspStudio(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),

                    // Master Volume Row (0% – 150% with Peak Limiter)
                    Row(
                      children: [
                        InkWell(
                          borderRadius: BorderRadius.circular(18),
                          onTap: () {
                            setState(() => _isMuted = !_isMuted);
                            _engine.setMute(_isMuted);
                          },
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              _isMuted || _cfg.volumePct == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              color: _isMuted ? skin.textMuted : skin.accent,
                              size: 20,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 56,
                          child: Text(
                            '${_cfg.volumePct}%',
                            maxLines: 1,
                            softWrap: false,
                            style: TextStyle(
                              color: _cfg.volumePct > 100
                                  ? skin.accent
                                  : skin.textMain,
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              fontFeatures: const [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                        Expanded(
                          child: SizedBox(
                            height: 30,
                            child: SliderTheme(
                              data: Theme.of(ctx).sliderTheme.copyWith(
                                trackHeight: 4.0,
                                overlayShape: const RoundSliderOverlayShape(
                                  overlayRadius: 12,
                                ),
                              ),
                              child: Slider(
                                min: 0,
                                max: 150,
                                value: _cfg.volumePct.toDouble().clamp(0, 150),
                                onChanged: (v) {
                                  final pct = v.round();
                                  setState(() {
                                    _cfg.volumePct = pct;
                                    if (_isMuted && pct > 0) _isMuted = false;
                                  });
                                  _engine.setMute(_isMuted);
                                  _engine.setVolume(pct / 100.0);
                                  _scheduleSave();
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // --------------------------------------------------------
                    // 2. Live 64-Band Spectrum Visualizer (Optional — OFF by default
                    //    for maximum spacious Playlist scrolling!)
                    // --------------------------------------------------------
                    if (_cfg.showSpectrum) ...[
                      SpectrumVisualizer(
                        skin: skin,
                        bars: _specBars,
                        peaks: _specPeaks,
                        repaintTick: _specTick,
                      ),
                      const SizedBox(height: 10),
                    ],

                    // --------------------------------------------------------
                    // 3. Playlist & Media Library Section
                    // --------------------------------------------------------
                    Text(
                      'Playlist & Media Library',
                      style: TextStyle(
                        color: skin.accent,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 7),

                    // Filter Input + Circular Library Action Buttons (+ / 📁 / 🗑)
                    Row(
                      children: [
                        Icon(Icons.search_rounded, color: skin.accent, size: 20),
                        const SizedBox(width: 6),
                        Expanded(
                          child: SizedBox(
                            height: 38,
                            child: TextField(
                              controller: _filterCtrl,
                              style: TextStyle(color: skin.textMain, fontSize: 13),
                              decoration: InputDecoration(
                                hintText: 'Filter tracks...',
                                hintStyle: TextStyle(
                                  color: skin.textMuted,
                                  fontSize: 12.5,
                                ),
                                filled: true,
                                fillColor: skin.cardBg,
                                isDense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 9,
                                ),
                                enabledBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: skin.border),
                                ),
                                focusedBorder: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                  borderSide: BorderSide(color: skin.accent),
                                ),
                                suffixIcon: _filterQuery.isNotEmpty
                                    ? IconButton(
                                        icon: Icon(
                                          Icons.close_rounded,
                                          size: 16,
                                          color: skin.textMuted,
                                        ),
                                        onPressed: () {
                                          _filterCtrl.clear();
                                          setState(() => _filterQuery = '');
                                        },
                                      )
                                    : null,
                              ),
                              onChanged: (v) => setState(() => _filterQuery = v),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.add_circle_outline_rounded,
                          size: 36,
                          onTap: () => _onPickFiles(ctx),
                        ),
                        const SizedBox(width: 6),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.folder_open_rounded,
                          size: 36,
                          onTap: () => _onOpenFolderPicker(ctx),
                        ),
                        const SizedBox(width: 6),
                        _CircleControlButton(
                          skin: skin,
                          icon: Icons.delete_outline_rounded,
                          size: 36,
                          onTap: _clearPlaylist,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),

                    // Scrollable Numbered Playlist Card
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          color: skin.cardBg,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: skin.border, width: 1),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: visible.isEmpty
                            ? Center(
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(14),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.library_music_outlined,
                                        size: 34,
                                        color: skin.textMuted,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _cfg.playlist.isEmpty
                                            ? 'Your Audiophile Library is empty'
                                            : 'No tracks match "$_filterQuery"',
                                        style: TextStyle(
                                          color: skin.textMain,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 13.5,
                                        ),
                                      ),
                                      if (_cfg.playlist.isEmpty) ...[
                                        const SizedBox(height: 10),
                                        ElevatedButton.icon(
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: skin.accent,
                                            foregroundColor: skin.accentFg,
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                          ),
                                          onPressed: () => _onOpenFolderPicker(ctx),
                                          icon: const Icon(
                                            Icons.folder_open_rounded,
                                            size: 18,
                                          ),
                                          label: const Text(
                                            'Scan Phone Music / Folders',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                              )
                            : Scrollbar(
                                controller: _listScrollCtrl,
                                thumbVisibility: true,
                                interactive: true,
                                radius: const Radius.circular(6),
                                child: ListView.separated(
                                  controller: _listScrollCtrl,
                                  padding: const EdgeInsets.symmetric(vertical: 2),
                                  itemCount: visible.length,
                                  separatorBuilder: (_, _) => Divider(
                                    height: 1,
                                    thickness: 0.6,
                                    color: skin.border.withValues(alpha: 0.35),
                                  ),
                                  itemBuilder: (_, listPos) {
                                    final trackIdx = visible[listPos];
                                    final item = _cfg.playlist[trackIdx];
                                    final isCurrent = _cfg.currentIdx == trackIdx;
                                    final numStr = (trackIdx + 1)
                                        .toString()
                                        .padLeft(2, '0');
                                    final display = item.artist.isEmpty
                                        ? '$numStr. ${item.title}'
                                        : '$numStr. ${item.title} — ${item.artist}';
                                    final rtl = isRtlText(item.title);

                                    return InkWell(
                                      onTap: () => _playTrackAt(trackIdx, ctx),
                                      onLongPress: () {
                                        setState(() {
                                          _cfg.playlist.removeAt(trackIdx);
                                          if (_cfg.currentIdx == trackIdx) {
                                            _stopPlayback();
                                            _cfg.currentIdx = null;
                                          } else if (_cfg.currentIdx != null &&
                                              _cfg.currentIdx! > trackIdx) {
                                            _cfg.currentIdx = _cfg.currentIdx! - 1;
                                          }
                                        });
                                        _scheduleSave();
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 10,
                                          vertical: 12,
                                        ),
                                        color: isCurrent
                                            ? skin.selectedRowBg
                                            : Colors.transparent,
                                        child: Row(
                                          children: [
                                            SizedBox(
                                              width: 22,
                                              child: isCurrent
                                                  ? Icon(
                                                      Icons.play_arrow_rounded,
                                                      color: skin.accent,
                                                      size: 19,
                                                    )
                                                  : null,
                                            ),
                                            Expanded(
                                              child: Text(
                                                display,
                                                textDirection: rtl
                                                    ? TextDirection.rtl
                                                    : TextDirection.ltr,
                                                style: TextStyle(
                                                  color: isCurrent
                                                      ? Colors.white
                                                      : skin.textMain,
                                                  fontSize: 13.8,
                                                  fontWeight: isCurrent
                                                      ? FontWeight.w700
                                                      : FontWeight.w500,
                                                ),
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ================================================================
            // Bottom Studio Status Bar (matches screenshot bottom strip 1:1)
            // ================================================================
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
              decoration: BoxDecoration(
                color: skin.btnBg,
                border: Border(top: BorderSide(color: skin.border, width: 1)),
              ),
              child: Row(
                children: [
                  Flexible(
                    flex: 5,
                    child: InkWell(
                      onTap: () {
                        setState(() => _cfg.autoHeadroom = !_cfg.autoHeadroom);
                        _engine.setAutoHeadroom(_cfg.autoHeadroom);
                        _scheduleSave();
                      },
                      child: Text(
                        'Headroom ${_cfg.autoHeadroom ? "ON" : "OFF"}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _cfg.autoHeadroom ? skin.accent : skin.textMain,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${_cfg.playlist.length} tracks',
                    maxLines: 1,
                    style: TextStyle(
                      color: skin.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 6,
                    child: Text(
                      '${skin.name} • ${_cfg.hasActiveEnhancements ? "32-Bit DSP+" : "32-Bit"}',
                      textAlign: TextAlign.end,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: skin.textMain,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleControlButton extends StatelessWidget {
  final StudioSkin skin;
  final IconData icon;
  final double size;
  final bool primary;
  final bool accentOutline;
  final bool highlighted;
  final VoidCallback onTap;

  const _CircleControlButton({
    required this.skin,
    required this.icon,
    required this.size,
    required this.onTap,
    this.primary = false,
    this.accentOutline = false,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = primary
        ? skin.accent
        : (highlighted ? skin.accent.withValues(alpha: 0.25) : skin.btnBg);
    final fg = primary
        ? skin.accentFg
        : (accentOutline || highlighted ? skin.accent : skin.textMain);
    final borderColor = primary
        ? skin.accent
        : (accentOutline || highlighted ? skin.accent : skin.border);

    return Material(
      color: bg,
      shape: CircleBorder(
        side: BorderSide(color: borderColor, width: accentOutline ? 1.5 : 1.0),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, color: fg, size: size * 0.52),
        ),
      ),
    );
  }
}
