// ============================================================================
// spectrum.rs — Real-Time 128-Bin FFT & 64-Band Logarithmic RTA Analyzer
// Exact ballistics & curve from Audio Engine V10 (main.rs)
// ============================================================================

use std::f32::consts::PI;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

use rustfft::num_complex::Complex;
use rustfft::{Fft, FftPlanner};

pub const FFT_SIZE: usize = 512;
pub const SPECTRUM_BARS: usize = 64;
const LINEAR_BINS: usize = 128;
const THRESHOLD_DB: f32 = -60.0;

/// Lock-free single-writer / single-reader sample tap written from audio callback.
pub struct SpectrumTap {
    ring: Box<[std::sync::atomic::AtomicU32; FFT_SIZE]>,
    write_pos: AtomicUsize,
}

impl SpectrumTap {
    pub fn new() -> Self {
        let vec: Vec<std::sync::atomic::AtomicU32> = (0..FFT_SIZE)
            .map(|_| std::sync::atomic::AtomicU32::new(0.0_f32.to_bits()))
            .collect();
        let ring: Box<[std::sync::atomic::AtomicU32; FFT_SIZE]> =
            vec.into_boxed_slice().try_into().ok().unwrap();
        Self {
            ring,
            write_pos: AtomicUsize::new(0),
        }
    }

    #[inline(always)]
    pub fn push(&self, sample: f32) {
        let pos = self.write_pos.load(Ordering::Relaxed);
        self.ring[pos & (FFT_SIZE - 1)].store(sample.to_bits(), Ordering::Relaxed);
        self.write_pos
            .store(pos.wrapping_add(1), Ordering::Release);
    }

    pub fn snapshot(&self, out: &mut [f32; FFT_SIZE]) {
        let end = self.write_pos.load(Ordering::Acquire);
        let start = end.wrapping_sub(FFT_SIZE);
        for (i, slot) in out.iter_mut().enumerate() {
            let idx = start.wrapping_add(i) & (FFT_SIZE - 1);
            *slot = f32::from_bits(self.ring[idx].load(Ordering::Relaxed));
        }
    }

    pub fn clear(&self) {
        for slot in self.ring.iter() {
            slot.store(0.0_f32.to_bits(), Ordering::Relaxed);
        }
    }
}

pub struct SpectrumAnalyzer {
    fft: Arc<dyn Fft<f32>>,
    window: [f32; FFT_SIZE],
    time_buf: [f32; FFT_SIZE],
    fft_buf: Vec<Complex<f32>>,
    linear_bins: [f32; LINEAR_BINS],
    pub bars: [f32; SPECTRUM_BARS],
    pub peaks: [f32; SPECTRUM_BARS],
}

impl SpectrumAnalyzer {
    pub fn new() -> Self {
        let mut planner = FftPlanner::<f32>::new();
        let fft = planner.plan_fft_forward(FFT_SIZE);

        let mut window = [0.0_f32; FFT_SIZE];
        for (i, w) in window.iter_mut().enumerate() {
            *w = 0.5 * (1.0 - (2.0 * PI * i as f32 / (FFT_SIZE - 1) as f32).cos());
        }

        Self {
            fft,
            window,
            time_buf: [0.0; FFT_SIZE],
            fft_buf: vec![Complex::new(0.0, 0.0); FFT_SIZE],
            linear_bins: [0.0; LINEAR_BINS],
            bars: [0.0; SPECTRUM_BARS],
            peaks: [0.0; SPECTRUM_BARS],
        }
    }

    /// Computes latest 64 logarithmic RTA bars + white peak-hold caps.
    pub fn update(&mut self, tap: &SpectrumTap, is_playing: bool) {
        if !is_playing {
            self.decay();
            return;
        }

        tap.snapshot(&mut self.time_buf);

        for i in 0..FFT_SIZE {
            self.fft_buf[i] = Complex::new(self.time_buf[i] * self.window[i], 0.0);
        }
        self.fft.process(&mut self.fft_buf);

        // Group 256 positive FFT bins into 128 linear magnitude bins in dB normalized [0..1]
        let norm_scale = 2.0 / (FFT_SIZE as f32 * 0.5); // compensate for Hann window gain
        for i in 0..LINEAR_BINS {
            let m0 = self.fft_buf[i * 2].norm();
            let m1 = self.fft_buf[i * 2 + 1].norm();
            let mag = (m0.max(m1) * norm_scale).max(1e-7);
            let db = 20.0 * mag.log10();
            self.linear_bins[i] = ((db - THRESHOLD_DB) / -THRESHOLD_DB).clamp(0.0, 1.0);
        }

        // Exact Audio Engine V10 64-band logarithmic RTA curve (from gtkplayer/src/main.rs)
        let usable_bins = (LINEAR_BINS * 3 / 4).max(1);
        let count = SPECTRUM_BARS;

        for i in 0..count {
            let t0 = (i as f32 / count as f32).powf(1.65);
            let t1 = ((i + 1) as f32 / count as f32).powf(1.65);

            let b0 = ((t0 * usable_bins as f32) as usize).min(usable_bins - 1);
            let b1 = ((t1 * usable_bins as f32).ceil() as usize).clamp(b0 + 1, usable_bins);

            let mut peak_bin = 0.0_f32;
            for &v in &self.linear_bins[b0..b1] {
                peak_bin = peak_bin.max(v);
            }

            let presence = 1.0 + 0.35 * (i as f32 / count as f32);
            let target = (peak_bin * presence).clamp(0.0, 1.0);

            if target > self.bars[i] {
                self.bars[i] = self.bars[i] * 0.25 + target * 0.75;
            } else {
                self.bars[i] = (self.bars[i] * 0.80).max(0.0);
            }

            if self.bars[i] >= self.peaks[i] {
                self.peaks[i] = self.bars[i];
            } else {
                self.peaks[i] = (self.peaks[i] - 0.018).max(self.bars[i]);
            }
        }
    }

    pub fn decay(&mut self) {
        for i in 0..SPECTRUM_BARS {
            if self.bars[i] > 0.004 || self.peaks[i] > 0.004 {
                self.bars[i] *= 0.82;
                self.peaks[i] = (self.peaks[i] - 0.022).max(self.bars[i]);
            } else {
                self.bars[i] = 0.0;
                self.peaks[i] = 0.0;
            }
        }
    }
}
