// ============================================================================
// dsp.rs — Pure 32-Bit Float (F32LE) 10-Band EQ, Spatial, Dynamics & Dither
// Faithful port of Audio Engine V10 DSP pipeline for real-time mobile playback
// ============================================================================

use std::f64::consts::PI;
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};

/// Official 10-band center frequencies (Hz) matching Audio Engine V10 desktop.
pub const EQ_FREQUENCIES: [f64; 10] = [
    29.0, 59.0, 119.0, 237.0, 474.0, 947.0, 1889.0, 3770.0, 7523.0, 15011.0,
];

/// Lock-free atomic DSP parameters shared between Dart UI thread and AAudio callback.
pub struct DspParams {
    pub eq_bands: [AtomicU64; 10],
    pub eq_dirty: AtomicBool,
    pub auto_headroom: AtomicBool,
    pub punch_enabled: AtomicBool,
    pub stereo_width: AtomicU32, // f32 bits (0.0..=1.0)
    pub room_reverb: AtomicU32,  // f32 bits (0.0..=1.0)
    pub balance: AtomicU32,      // f32 bits (-1.0..=1.0)
    pub volume: AtomicU64,       // f64 bits (0.0..=1.5)
    pub muted: AtomicBool,
}

impl Default for DspParams {
    fn default() -> Self {
        Self::new()
    }
}

impl DspParams {
    pub fn new() -> Self {
        Self {
            eq_bands: std::array::from_fn(|_| AtomicU64::new(0.0_f64.to_bits())),
            eq_dirty: AtomicBool::new(true),
            auto_headroom: AtomicBool::new(true),
            punch_enabled: AtomicBool::new(false),
            stereo_width: AtomicU32::new(0.0_f32.to_bits()),
            room_reverb: AtomicU32::new(0.0_f32.to_bits()),
            balance: AtomicU32::new(0.0_f32.to_bits()),
            volume: AtomicU64::new(0.8_f64.to_bits()),
            muted: AtomicBool::new(false),
        }
    }

    pub fn set_eq_band(&self, idx: usize, gain_db: f64) {
        if idx < 10 {
            let clamped = gain_db.clamp(-12.0, 12.0);
            self.eq_bands[idx].store(clamped.to_bits(), Ordering::Relaxed);
            self.eq_dirty.store(true, Ordering::Release);
        }
    }

    pub fn set_all_eq_bands(&self, gains: &[f64; 10]) {
        for (i, &g) in gains.iter().enumerate() {
            let clamped = g.clamp(-12.0, 12.0);
            self.eq_bands[i].store(clamped.to_bits(), Ordering::Relaxed);
        }
        self.eq_dirty.store(true, Ordering::Release);
    }

    pub fn get_eq_bands(&self) -> [f64; 10] {
        std::array::from_fn(|i| f64::from_bits(self.eq_bands[i].load(Ordering::Relaxed)))
    }

    pub fn set_auto_headroom(&self, enabled: bool) {
        self.auto_headroom.store(enabled, Ordering::Relaxed);
    }

    pub fn set_punch_enabled(&self, enabled: bool) {
        self.punch_enabled.store(enabled, Ordering::Relaxed);
    }

    pub fn set_stereo_width(&self, amount: f32) {
        self.stereo_width
            .store(amount.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_room_reverb(&self, amount: f32) {
        self.room_reverb
            .store(amount.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_balance(&self, pan: f32) {
        self.balance
            .store(pan.clamp(-1.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    pub fn set_volume(&self, vol: f64) {
        self.volume
            .store(vol.clamp(0.0, 1.5).to_bits(), Ordering::Relaxed);
    }

    pub fn set_muted(&self, muted: bool) {
        self.muted.store(muted, Ordering::Relaxed);
    }

    pub fn reset_dsp_effects(&self) {
        self.set_stereo_width(0.0);
        self.set_punch_enabled(false);
        self.set_room_reverb(0.0);
        self.set_auto_headroom(true);
    }
}

// ============================================================================
// Stereo Peaking Biquad Filter (Direct Form II Transposed, f64 coeffs)
// ============================================================================

#[derive(Clone)]
struct StereoBiquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
    z1_l: f64,
    z2_l: f64,
    z1_r: f64,
    z2_r: f64,
    active: bool,
}

impl StereoBiquad {
    fn new() -> Self {
        Self {
            b0: 1.0,
            b1: 0.0,
            b2: 0.0,
            a1: 0.0,
            a2: 0.0,
            z1_l: 0.0,
            z2_l: 0.0,
            z1_r: 0.0,
            z2_r: 0.0,
            active: false,
        }
    }

    /// Configures an RBJ Peaking EQ filter (Q = 1.414 ≈ 1-octave bandwidth).
    fn set_peaking(&mut self, sample_rate: f64, freq_hz: f64, gain_db: f64, q: f64) {
        if gain_db.abs() < 0.01 || freq_hz >= sample_rate * 0.48 {
            self.b0 = 1.0;
            self.b1 = 0.0;
            self.b2 = 0.0;
            self.a1 = 0.0;
            self.a2 = 0.0;
            self.active = false;
            return;
        }

        let a_lin = 10.0_f64.powf(gain_db / 40.0);
        let w0 = 2.0 * PI * (freq_hz / sample_rate);
        let cos_w0 = w0.cos();
        let sin_w0 = w0.sin();
        let alpha = sin_w0 / (2.0 * q);

        let b0 = 1.0 + alpha * a_lin;
        let b1 = -2.0 * cos_w0;
        let b2 = 1.0 - alpha * a_lin;
        let a0 = 1.0 + alpha / a_lin;
        let a1 = -2.0 * cos_w0;
        let a2 = 1.0 - alpha / a_lin;

        let inv_a0 = 1.0 / a0;
        self.b0 = b0 * inv_a0;
        self.b1 = b1 * inv_a0;
        self.b2 = b2 * inv_a0;
        self.a1 = a1 * inv_a0;
        self.a2 = a2 * inv_a0;
        self.active = true;
    }

    #[inline(always)]
    fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        if !self.active {
            return (l, r);
        }
        let xl = l as f64;
        let yl = self.b0 * xl + self.z1_l;
        self.z1_l = self.b1 * xl - self.a1 * yl + self.z2_l;
        self.z2_l = self.b2 * xl - self.a2 * yl;

        let xr = r as f64;
        let yr = self.b0 * xr + self.z1_r;
        self.z1_r = self.b1 * xr - self.a1 * yr + self.z2_r;
        self.z2_r = self.b2 * xr - self.a2 * yr;

        (yl as f32, yr as f32)
    }

    fn reset_state(&mut self) {
        self.z1_l = 0.0;
        self.z2_l = 0.0;
        self.z1_r = 0.0;
        self.z2_r = 0.0;
    }
}

// ============================================================================
// Soft-Knee Studio Punch Compressor (matches GStreamer audiodynamic soft-knee)
// ============================================================================

struct SoftKneeCompressor {
    env: f32,
    attack_coeff: f32,
    release_coeff: f32,
}

impl SoftKneeCompressor {
    fn new(sample_rate: f32) -> Self {
        let mut c = Self {
            env: 0.0,
            attack_coeff: 0.0,
            release_coeff: 0.0,
        };
        c.set_sample_rate(sample_rate);
        c
    }

    fn set_sample_rate(&mut self, sr: f32) {
        let sr = sr.max(8000.0);
        self.attack_coeff = (-1.0 / (0.005 * sr)).exp();
        self.release_coeff = (-1.0 / (0.080 * sr)).exp();
    }

    #[inline(always)]
    fn process(&mut self, l: f32, r: f32, enabled: bool) -> (f32, f32) {
        if !enabled {
            self.env *= 0.99;
            return (l, r);
        }
        const THRESHOLD: f32 = 0.42;
        const RATIO: f32 = 0.65;
        const KNEE: f32 = 0.14;

        let peak = l.abs().max(r.abs());
        if peak > self.env {
            self.env = self.attack_coeff * self.env + (1.0 - self.attack_coeff) * peak;
        } else {
            self.env = self.release_coeff * self.env + (1.0 - self.release_coeff) * peak;
        }

        let gain = if self.env <= THRESHOLD - KNEE * 0.5 {
            1.0
        } else if self.env < THRESHOLD + KNEE * 0.5 {
            // Smooth quadratic soft-knee transition
            let x = (self.env - (THRESHOLD - KNEE * 0.5)) / KNEE;
            let excess = self.env - THRESHOLD;
            let compressed = THRESHOLD + excess * RATIO;
            let full_gain = if self.env > 1e-6 {
                compressed / self.env
            } else {
                1.0
            };
            1.0 + (full_gain - 1.0) * (x * x)
        } else {
            let compressed = THRESHOLD + (self.env - THRESHOLD) * RATIO;
            compressed / self.env.max(1e-6)
        };

        (l * gain, r * gain)
    }

    fn reset(&mut self) {
        self.env = 0.0;
    }
}

// ============================================================================
// Pure F32LE Jezar Freeverb Acoustic Room Ambience (8 Comb + 4 Allpass)
// ============================================================================

const COMB_TUNINGS_44K: [usize; 8] = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617];
const ALLPASS_TUNINGS_44K: [usize; 4] = [556, 441, 341, 225];
const STEREO_SPREAD_44K: usize = 23;

struct CombFilter {
    buf: Vec<f32>,
    idx: usize,
    filter_store: f32,
}

impl CombFilter {
    fn new(size: usize) -> Self {
        Self {
            buf: vec![0.0; size.max(1)],
            idx: 0,
            filter_store: 0.0,
        }
    }

    #[inline(always)]
    fn process(&mut self, input: f32, feedback: f32, damp1: f32, damp2: f32) -> f32 {
        let output = self.buf[self.idx];
        self.filter_store = (output * damp2) + (self.filter_store * damp1);
        // Prevent denormals
        if self.filter_store.abs() < 1e-20 {
            self.filter_store = 0.0;
        }
        self.buf[self.idx] = input + (self.filter_store * feedback);
        self.idx += 1;
        if self.idx >= self.buf.len() {
            self.idx = 0;
        }
        output
    }

    fn clear(&mut self) {
        self.buf.fill(0.0);
        self.filter_store = 0.0;
        self.idx = 0;
    }
}

struct AllpassFilter {
    buf: Vec<f32>,
    idx: usize,
}

impl AllpassFilter {
    fn new(size: usize) -> Self {
        Self {
            buf: vec![0.0; size.max(1)],
            idx: 0,
        }
    }

    #[inline(always)]
    fn process(&mut self, input: f32) -> f32 {
        let bufout = self.buf[self.idx];
        let output = -input + bufout;
        self.buf[self.idx] = input + (bufout * 0.5);
        self.idx += 1;
        if self.idx >= self.buf.len() {
            self.idx = 0;
        }
        output
    }

    fn clear(&mut self) {
        self.buf.fill(0.0);
        self.idx = 0;
    }
}

struct Freeverb {
    combs_l: Vec<CombFilter>,
    combs_r: Vec<CombFilter>,
    allpasses_l: Vec<AllpassFilter>,
    allpasses_r: Vec<AllpassFilter>,
}

impl Freeverb {
    fn new(sample_rate: f32) -> Self {
        let scale = (sample_rate / 44100.0).clamp(0.5, 4.5);
        let spread = ((STEREO_SPREAD_44K as f32) * scale).round() as usize;

        let combs_l = COMB_TUNINGS_44K
            .iter()
            .map(|&n| CombFilter::new(((n as f32) * scale).round() as usize))
            .collect();
        let combs_r = COMB_TUNINGS_44K
            .iter()
            .map(|&n| CombFilter::new(((n as f32) * scale).round() as usize + spread))
            .collect();
        let allpasses_l = ALLPASS_TUNINGS_44K
            .iter()
            .map(|&n| AllpassFilter::new(((n as f32) * scale).round() as usize))
            .collect();
        let allpasses_r = ALLPASS_TUNINGS_44K
            .iter()
            .map(|&n| AllpassFilter::new(((n as f32) * scale).round() as usize + spread))
            .collect();

        Self {
            combs_l,
            combs_r,
            allpasses_l,
            allpasses_r,
        }
    }

    #[inline(always)]
    fn process(&mut self, l: f32, r: f32, amount: f32) -> (f32, f32) {
        if amount <= 0.001 {
            return (l, r);
        }
        // Match audio.rs Freeverb scaling:
        // level = amount * 0.28, room-size = 0.25 + amount * 0.45, damping = 0.55
        let wet = amount * 0.28;
        let room_size = 0.25 + amount * 0.45;
        let feedback = 0.28 + room_size * 0.68; // keeps reverb musical & never runaway
        let damp1 = 0.55 * 0.4;
        let damp2 = 1.0 - damp1;

        let mono_in = (l + r) * 0.015;
        let mut out_l = 0.0_f32;
        let mut out_r = 0.0_f32;

        for c in &mut self.combs_l {
            out_l += c.process(mono_in, feedback, damp1, damp2);
        }
        for c in &mut self.combs_r {
            out_r += c.process(mono_in, feedback, damp1, damp2);
        }
        for ap in &mut self.allpasses_l {
            out_l = ap.process(out_l);
        }
        for ap in &mut self.allpasses_r {
            out_r = ap.process(out_r);
        }

        (l + out_l * wet, r + out_r * wet)
    }

    fn clear(&mut self) {
        for c in &mut self.combs_l {
            c.clear();
        }
        for c in &mut self.combs_r {
            c.clear();
        }
        for ap in &mut self.allpasses_l {
            ap.clear();
        }
        for ap in &mut self.allpasses_r {
            ap.clear();
        }
    }
}

// ============================================================================
// Transparent Post-Volume Peak Limiter + TPDF Dither
// ============================================================================

struct PeakLimiter {
    env: f32,
    attack_coeff: f32,
    release_coeff: f32,
}

impl PeakLimiter {
    fn new(sample_rate: f32) -> Self {
        let mut lim = Self {
            env: 1.0,
            attack_coeff: 0.0,
            release_coeff: 0.0,
        };
        lim.set_sample_rate(sample_rate);
        lim
    }

    fn set_sample_rate(&mut self, sr: f32) {
        let sr = sr.max(8000.0);
        self.attack_coeff = (-1.0 / (0.0004 * sr)).exp();
        self.release_coeff = (-1.0 / (0.055 * sr)).exp();
    }

    #[inline(always)]
    fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        const CEILING: f32 = 0.985;
        let peak = l.abs().max(r.abs());
        let desired_gain = if peak > CEILING {
            CEILING / peak
        } else {
            1.0
        };

        if desired_gain < self.env {
            self.env = self.attack_coeff * self.env + (1.0 - self.attack_coeff) * desired_gain;
        } else {
            self.env = self.release_coeff * self.env + (1.0 - self.release_coeff) * desired_gain;
        }

        let mut ol = l * self.env;
        let mut or = r * self.env;

        // Soft safety saturation for extreme sub-millisecond transients
        if ol.abs() > 0.99 {
            ol = ol.signum() * (0.99 + 0.01 * ((ol.abs() - 0.99) / 0.01).tanh());
        }
        if or.abs() > 0.99 {
            or = or.signum() * (0.99 + 0.01 * ((or.abs() - 0.99) / 0.01).tanh());
        }
        (ol, or)
    }

    fn reset(&mut self) {
        self.env = 1.0;
    }
}

/// Fast xorshift32 TPDF dither generator with subtle first-order noise shaping (24-bit floor).
struct TpdfDither {
    rng_state: u32,
    prev_err_l: f32,
    prev_err_r: f32,
}

impl TpdfDither {
    fn new() -> Self {
        Self {
            rng_state: 0xA10E_5710,
            prev_err_l: 0.0,
            prev_err_r: 0.0,
        }
    }

    #[inline(always)]
    fn next_unit(&mut self) -> f32 {
        let mut x = self.rng_state;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        self.rng_state = x;
        (x as f32) * (1.0 / u32::MAX as f32) - 0.5
    }

    #[inline(always)]
    fn process(&mut self, l: f32, r: f32) -> (f32, f32) {
        // 24-bit LSB scale (~1.19e-7) triangular PDF dither + mild HP noise shaping
        const LSB_24: f32 = 1.0 / 8_388_608.0;
        let tpdf_l = (self.next_unit() + self.next_unit()) * LSB_24;
        let tpdf_r = (self.next_unit() + self.next_unit()) * LSB_24;
        let out_l = (l + tpdf_l - 0.5 * self.prev_err_l).clamp(-1.0, 1.0);
        let out_r = (r + tpdf_r - 0.5 * self.prev_err_r).clamp(-1.0, 1.0);
        self.prev_err_l = tpdf_l;
        self.prev_err_r = tpdf_r;
        (out_l, out_r)
    }
}

// ============================================================================
// Complete Audio Engine V10 Pure 32-Bit Float DSP Chain
// ============================================================================

pub struct DspChain {
    sample_rate: f64,
    eq: [StereoBiquad; 10],
    compressor: SoftKneeCompressor,
    reverb: Freeverb,
    limiter: PeakLimiter,
    dither: TpdfDither,
    // Smoothly ramped parameters (click-free live modulation!)
    smooth_pre_gain: f32,
    smooth_volume: f32,
    smooth_stereo: f32,
    smooth_reverb: f32,
    smooth_balance: f32,
    cached_max_boost_db: f64,
}

impl DspChain {
    pub fn new(sample_rate: u32) -> Self {
        let sr = sample_rate.max(8000) as f64;
        Self {
            sample_rate: sr,
            eq: std::array::from_fn(|_| StereoBiquad::new()),
            compressor: SoftKneeCompressor::new(sr as f32),
            reverb: Freeverb::new(sr as f32),
            limiter: PeakLimiter::new(sr as f32),
            dither: TpdfDither::new(),
            smooth_pre_gain: 1.0,
            smooth_volume: 0.8,
            smooth_stereo: 0.0,
            smooth_reverb: 0.0,
            smooth_balance: 0.0,
            cached_max_boost_db: 0.0,
        }
    }

    pub fn set_sample_rate(&mut self, sample_rate: u32, params: &DspParams) {
        let sr = sample_rate.max(8000) as f64;
        if (self.sample_rate - sr).abs() < 1.0 {
            return;
        }
        self.sample_rate = sr;
        self.compressor.set_sample_rate(sr as f32);
        self.reverb = Freeverb::new(sr as f32);
        self.limiter.set_sample_rate(sr as f32);
        self.sync_eq(params);
    }

    pub fn reset_state(&mut self) {
        for b in &mut self.eq {
            b.reset_state();
        }
        self.compressor.reset();
        self.reverb.clear();
        self.limiter.reset();
    }

    fn sync_eq(&mut self, params: &DspParams) {
        let gains = params.get_eq_bands();
        let mut max_boost = 0.0_f64;
        for (i, &g) in gains.iter().enumerate() {
            if g > max_boost {
                max_boost = g;
            }
            self.eq[i].set_peaking(self.sample_rate, EQ_FREQUENCIES[i], g, 1.414);
        }
        self.cached_max_boost_db = max_boost;
    }

    /// Processes stereo interleaved `f32` frames in-place, and emits pre-master-volume
    /// mono samples into `spectrum_tap` for real-time 128-bin FFT visualization.
    pub fn process_interleaved(
        &mut self,
        interleaved: &mut [f32],
        params: &DspParams,
        mut spectrum_tap: impl FnMut(f32),
    ) {
        if params.eq_dirty.swap(false, Ordering::AcqRel) {
            self.sync_eq(params);
        }

        let auto_headroom = params.auto_headroom.load(Ordering::Relaxed);
        let punch_enabled = params.punch_enabled.load(Ordering::Relaxed);
        let target_stereo = f32::from_bits(params.stereo_width.load(Ordering::Relaxed));
        let target_reverb = f32::from_bits(params.room_reverb.load(Ordering::Relaxed));
        let target_balance = f32::from_bits(params.balance.load(Ordering::Relaxed));
        let muted = params.muted.load(Ordering::Relaxed);
        let target_volume = if muted {
            0.0
        } else {
            f64::from_bits(params.volume.load(Ordering::Relaxed)) as f32
        };

        let base_headroom = if !auto_headroom || self.cached_max_boost_db <= 0.0 {
            1.0_f32
        } else {
            10.0_f64.powf(-self.cached_max_boost_db / 20.0) as f32
        };
        let punch_makeup = if punch_enabled { 1.15_f32 } else { 1.0_f32 };
        let target_pre_gain = base_headroom * punch_makeup;

        // Per-sample smoothing factor (~5ms ramp at 48kHz)
        let ramp = 0.004_f32;

        for frame in interleaved.chunks_exact_mut(2) {
            self.smooth_pre_gain += (target_pre_gain - self.smooth_pre_gain) * ramp;
            self.smooth_volume += (target_volume - self.smooth_volume) * ramp;
            self.smooth_stereo += (target_stereo - self.smooth_stereo) * ramp;
            self.smooth_reverb += (target_reverb - self.smooth_reverb) * ramp;
            self.smooth_balance += (target_balance - self.smooth_balance) * ramp;

            // 1. Smart Pre-Gain (Auto Headroom + optional Studio Punch makeup)
            let mut l = frame[0] * self.smooth_pre_gain;
            let mut r = frame[1] * self.smooth_pre_gain;

            // 2. 10-Band Pure F32LE Graphic Studio Equalizer
            for band in &mut self.eq {
                (l, r) = band.process(l, r);
            }

            // 3. Optional Soft-Knee Studio Punch Compressor
            (l, r) = self.compressor.process(l, r, punch_enabled);

            // 4. Optional Pure F32LE Mid/Side Stereo Widener (exact 2x2 matrix)
            if self.smooth_stereo > 0.0005 {
                let b = -0.35_f32 * self.smooth_stereo;
                let nl = l + b * r;
                let nr = b * l + r;
                l = nl;
                r = nr;
            }

            // 5. Optional Acoustic Room Ambience (Jezar Freeverb)
            (l, r) = self.reverb.process(l, r, self.smooth_reverb);

            // 6. Stereo Panorama / Balance
            if self.smooth_balance < -0.001 {
                r *= (1.0 + self.smooth_balance).clamp(0.0, 1.0);
            } else if self.smooth_balance > 0.001 {
                l *= (1.0 - self.smooth_balance).clamp(0.0, 1.0);
            }

            // 7. Pre-Master-Volume Spectrum Tap (bars stay vivid at any speaker volume!)
            spectrum_tap((l + r) * 0.5);

            // 8. Master Volume & Mute (up to 150% with Limiter protection)
            l *= self.smooth_volume;
            r *= self.smooth_volume;

            // 9. Post-Volume ReplayGain Peak Limiter
            (l, r) = self.limiter.process(l, r);

            // 10. TPDF Dithering + Noise Shaping + Safety Clamp
            (l, r) = self.dither.process(l, r);

            frame[0] = if l.is_finite() { l } else { 0.0 };
            frame[1] = if r.is_finite() { r } else { 0.0 };
        }
    }
}
