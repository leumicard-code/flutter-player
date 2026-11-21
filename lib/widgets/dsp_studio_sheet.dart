// ============================================================================
// dsp_studio_sheet.dart — Equalizer & 32-Bit Float DSP Studio Bottom Sheet
// Mirrors open_equalizer_window() from Audio Engine V10 Desktop 1:1
// ============================================================================

import 'package:material_ui/material_ui.dart';

import '../models/player_models.dart';
import '../theme/studio_theme.dart';

class DspStudioSheet extends StatefulWidget {
  final StudioSkin skin;
  final PlayerConfig config;
  final void Function(int band, double gainDb) onEqBandChanged;
  final void Function(EqPreset preset) onPresetSelected;
  final void Function(bool enabled) onAutoHeadroomChanged;
  final void Function(int pct) onStereoWidthChanged;
  final void Function(int pct) onRoomReverbChanged;
  final void Function(int pct) onBalanceChanged;
  final void Function(bool enabled) onPunchChanged;
  final VoidCallback onResetDsp;

  const DspStudioSheet({
    super.key,
    required this.skin,
    required this.config,
    required this.onEqBandChanged,
    required this.onPresetSelected,
    required this.onAutoHeadroomChanged,
    required this.onStereoWidthChanged,
    required this.onRoomReverbChanged,
    required this.onBalanceChanged,
    required this.onPunchChanged,
    required this.onResetDsp,
  });

  @override
  State<DspStudioSheet> createState() => _DspStudioSheetState();
}

class _DspStudioSheetState extends State<DspStudioSheet> {
  StudioSkin get skin => widget.skin;
  PlayerConfig get cfg => widget.config;

  String _formatDb(double db) {
    final rounded = db.round();
    if (rounded > 0) return '+${rounded}dB';
    return '${rounded}dB';
  }

  String _formatBalance(int pct) {
    if (pct == 0) return 'Center';
    if (pct < 0) return 'L ${pct.abs()}%';
    return 'R $pct%';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: skin.panelBg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border(top: BorderSide(color: skin.border, width: 1.2)),
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 42,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: skin.border,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Header + Auto Headroom Toggle
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '10-Band EQ & 32-Bit DSP Studio',
                          style: TextStyle(
                            color: skin.textMain,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'Pure F32LE path • Sinc Resampler • Peak Limiter',
                          style: TextStyle(
                            color: skin.textMuted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  _TogglePill(
                    skin: skin,
                    active: cfg.autoHeadroom,
                    label: cfg.autoHeadroom ? '✓ Headroom ON' : 'Headroom OFF',
                    onTap: () {
                      setState(() {
                        widget.onAutoHeadroomChanged(!cfg.autoHeadroom);
                      });
                    },
                  ),
                ],
              ),

              const SizedBox(height: 14),

              // Studio Presets
              _SectionBox(
                skin: skin,
                title: 'Studio Presets',
                child: Wrap(
                  spacing: 7,
                  runSpacing: 7,
                  children: EqPreset.values.map((preset) {
                    final gains = preset.gains;
                    bool isMatch = true;
                    for (int i = 0; i < 10; i++) {
                      if ((cfg.eqBands[i] - gains[i]).abs() > 0.15) {
                        isMatch = false;
                        break;
                      }
                    }
                    return _TogglePill(
                      skin: skin,
                      active: isMatch,
                      label: preset.label,
                      onTap: () {
                        setState(() {
                          widget.onPresetSelected(preset);
                        });
                      },
                    );
                  }).toList(),
                ),
              ),

              const SizedBox(height: 12),

              // 10-Band Vertical Frequency Response Faders
              _SectionBox(
                skin: skin,
                title: 'Frequency Response Faders (-12dB to +12dB)',
                child: SizedBox(
                  height: 215,
                  child: Row(
                    children: List.generate(10, (idx) {
                      final val = cfg.eqBands[idx];
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 1),
                          child: Column(
                            children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  _formatDb(val),
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: val.abs() > 0.2 ? skin.accent : skin.textMuted,
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w700,
                                    fontFeatures: const [FontFeature.tabularFigures()],
                                  ),
                                ),
                              ),
                              Expanded(
                                child: RotatedBox(
                                  quarterTurns: 3,
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 3.2,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 6.5,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(
                                        overlayRadius: 13,
                                      ),
                                      activeTrackColor: skin.accent,
                                      inactiveTrackColor: skin.specSlot,
                                      thumbColor: skin.textMain,
                                    ),
                                    child: Slider(
                                      min: -12.0,
                                      max: 12.0,
                                      divisions: 48,
                                      value: val.clamp(-12.0, 12.0),
                                      onChanged: (v) {
                                        setState(() {
                                          widget.onEqBandChanged(idx, v);
                                        });
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  formatEqFreq(eqFrequenciesHz[idx]),
                                  maxLines: 1,
                                  style: TextStyle(
                                    color: skin.textMuted,
                                    fontSize: 9.2,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // Pure 32-Bit Float Spatial & Dynamics DSP Section
              _SectionBox(
                skin: skin,
                title: '32-Bit Float Spatial & Dynamics DSP (Optional)',
                child: Column(
                  children: [
                    _DspSliderRow(
                      skin: skin,
                      label: 'Stereo Stage',
                      valueText: cfg.stereoWidthPct <= 0
                          ? '0% (Pure)'
                          : '${cfg.stereoWidthPct}%',
                      value: cfg.stereoWidthPct.toDouble(),
                      min: 0,
                      max: 100,
                      onChanged: (v) {
                        setState(() {
                          widget.onStereoWidthChanged(v.round());
                        });
                      },
                    ),
                    _DspSliderRow(
                      skin: skin,
                      label: 'Room Ambience',
                      valueText: cfg.roomReverbPct <= 0
                          ? '0% (Dry)'
                          : '${cfg.roomReverbPct}%',
                      value: cfg.roomReverbPct.toDouble(),
                      min: 0,
                      max: 100,
                      onChanged: (v) {
                        setState(() {
                          widget.onRoomReverbChanged(v.round());
                        });
                      },
                    ),
                    _DspSliderRow(
                      skin: skin,
                      label: 'Stereo Balance',
                      valueText: _formatBalance(cfg.balancePct),
                      value: cfg.balancePct.toDouble(),
                      min: -100,
                      max: 100,
                      onChanged: (v) {
                        setState(() {
                          final rounded = v.round();
                          // Gentle center detent
                          final snapped = rounded.abs() <= 4 ? 0 : rounded;
                          widget.onBalanceChanged(snapped);
                        });
                      },
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: _TogglePill(
                            skin: skin,
                            active: cfg.punchEnabled,
                            label: cfg.punchEnabled
                                ? '● Studio Punch: ON'
                                : '○ Studio Punch: OFF',
                            onTap: () {
                              setState(() {
                                widget.onPunchChanged(!cfg.punchEnabled);
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        _TogglePill(
                          skin: skin,
                          active: false,
                          label: '↺ Pure 32-Bit Default',
                          onTap: () {
                            setState(() {
                              widget.onResetDsp();
                            });
                          },
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionBox extends StatelessWidget {
  final StudioSkin skin;
  final String title;
  final Widget child;

  const _SectionBox({
    required this.skin,
    required this.title,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        color: skin.cardBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: skin.border, width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: skin.accent,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _DspSliderRow extends StatelessWidget {
  final StudioSkin skin;
  final String label;
  final String valueText;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  const _DspSliderRow({
    required this.skin,
    required this.label,
    required this.valueText,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 102,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: skin.textMain,
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: skin.accent,
              inactiveTrackColor: skin.specSlot,
              thumbColor: skin.textMain,
              trackHeight: 3.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            ),
            child: Slider(
              min: min,
              max: max,
              value: value.clamp(min, max),
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 72,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerRight,
            child: Text(
              valueText,
              maxLines: 1,
              textAlign: TextAlign.end,
              style: TextStyle(
                color: skin.accent,
                fontSize: 11.5,
                fontWeight: FontWeight.w700,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _TogglePill extends StatelessWidget {
  final StudioSkin skin;
  final bool active;
  final String label;
  final VoidCallback onTap;

  const _TogglePill({
    required this.skin,
    required this.active,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: active ? skin.accent : skin.btnBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? skin.accent : skin.border,
            width: 1,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: active ? skin.accentFg : skin.textMain,
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
