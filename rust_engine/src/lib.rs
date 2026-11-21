// ============================================================================
// lib.rs — Audio Engine V10 Pure 32-Bit Float Android Engine & Dart FFI API
// ============================================================================

pub mod aaudio;
pub mod decoder;
pub mod dsp;
pub mod spectrum;

use std::ffi::{c_char, CStr};
use std::sync::atomic::{AtomicBool, AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use ringbuf::traits::{Consumer, Observer, Producer, Split};
use ringbuf::{HeapCons, HeapProd, HeapRb};

use crate::aaudio::NativeAudioOutput;
use crate::decoder::{AudioDecoder, TrackMetadata};
use crate::dsp::{DspChain, DspParams};
use crate::spectrum::{SpectrumAnalyzer, SpectrumTap, SPECTRUM_BARS};

/// ~0.68 seconds of stereo 32-bit float audio @ 48kHz (65536 floats = 32768 stereo frames)
const RING_SAMPLES: usize = 65536;

enum DecoderCommand {
    Seek(f64),
    Stop,
}

struct SharedAudioState {
    params: Arc<DspParams>,
    tap: Arc<SpectrumTap>,
    playing: Arc<AtomicBool>,
    decoder_eof: Arc<AtomicBool>,
    eos_triggered: Arc<AtomicBool>,
    needs_reopen: Arc<AtomicBool>,
    reset_dsp_only: Arc<AtomicBool>,
    output_sample_rate: Arc<AtomicU32>,
    /// Current playback position in milliseconds (updated from real-time callback & seek)
    position_ms: Arc<AtomicU64>,
    duration_ms: Arc<AtomicU64>,
}

pub struct AudioEngineV10 {
    shared: SharedAudioState,
    output: Option<NativeAudioOutput>,
    /// Consumer guarded by Mutex; RT callback uses non-blocking `try_lock()`, while
    /// load/seek can synchronously clear stale samples without racing the decoder!
    consumer_mtx: Arc<Mutex<HeapCons<f32>>>,
    producer_slot: Arc<Mutex<Option<HeapProd<f32>>>>,
    decoder_cmd_tx: Option<std::sync::mpsc::Sender<DecoderCommand>>,
    decoder_thread: Option<JoinHandle<()>>,
    spectrum: Mutex<SpectrumAnalyzer>,
    metadata: Mutex<TrackMetadata>,
    last_error: Mutex<String>,
}

impl AudioEngineV10 {
    pub fn new() -> Result<Self, String> {
        let rb = HeapRb::<f32>::new(RING_SAMPLES);
        let (prod, cons) = rb.split();

        let shared = SharedAudioState {
            params: Arc::new(DspParams::new()),
            tap: Arc::new(SpectrumTap::new()),
            playing: Arc::new(AtomicBool::new(false)),
            decoder_eof: Arc::new(AtomicBool::new(false)),
            eos_triggered: Arc::new(AtomicBool::new(false)),
            needs_reopen: Arc::new(AtomicBool::new(false)),
            reset_dsp_only: Arc::new(AtomicBool::new(false)),
            output_sample_rate: Arc::new(AtomicU32::new(48000)),
            position_ms: Arc::new(AtomicU64::new(0)),
            duration_ms: Arc::new(AtomicU64::new(0)),
        };

        let consumer_mtx = Arc::new(Mutex::new(cons));
        let producer_slot = Arc::new(Mutex::new(Some(prod)));

        let mut engine = Self {
            shared,
            output: None,
            consumer_mtx,
            producer_slot,
            decoder_cmd_tx: None,
            decoder_thread: None,
            spectrum: Mutex::new(SpectrumAnalyzer::new()),
            metadata: Mutex::new(TrackMetadata::default()),
            last_error: Mutex::new(String::new()),
        };

        engine.open_output_stream()?;
        Ok(engine)
    }

    fn open_output_stream(&mut self) -> Result<(), String> {
        self.output = None;

        let consumer_mtx = Arc::clone(&self.consumer_mtx);
        let params = Arc::clone(&self.shared.params);
        let tap = Arc::clone(&self.shared.tap);
        let playing = Arc::clone(&self.shared.playing);
        let decoder_eof = Arc::clone(&self.shared.decoder_eof);
        let eos_triggered = Arc::clone(&self.shared.eos_triggered);
        let needs_reopen = Arc::clone(&self.shared.needs_reopen);
        let reset_dsp_only = Arc::clone(&self.shared.reset_dsp_only);
        let out_sr = Arc::clone(&self.shared.output_sample_rate);
        let position_ms = Arc::clone(&self.shared.position_ms);

        let mut dsp = DspChain::new(out_sr.load(Ordering::Relaxed));
        let mut fractional_frames: f64 = 0.0;

        let render = Box::new(move |out: &mut [f32]| {
            let sr = out_sr.load(Ordering::Relaxed).max(8000);
            dsp.set_sample_rate(sr, &params);

            if reset_dsp_only.swap(false, Ordering::AcqRel) {
                dsp.reset_state();
                fractional_frames = 0.0;
            }

            if !playing.load(Ordering::Acquire) {
                out.fill(0.0);
                return;
            }

            let read = match consumer_mtx.try_lock() {
                Ok(mut cons) => cons.pop_slice(out),
                Err(_) => 0,
            };

            if read < out.len() {
                out[read..].fill(0.0);
                if read == 0 && decoder_eof.load(Ordering::Acquire) {
                    playing.store(false, Ordering::Release);
                    eos_triggered.store(true, Ordering::Release);
                    return;
                }
            }

            // Advance playback clock accurately by consumed stereo frames
            let frames_read = (read / 2) as f64;
            fractional_frames += frames_read;
            let ms_delta = (fractional_frames * 1000.0 / sr as f64).floor() as u64;
            if ms_delta > 0 {
                fractional_frames -= (ms_delta as f64) * (sr as f64) / 1000.0;
                position_ms.fetch_add(ms_delta, Ordering::Relaxed);
            }

            // Run Pure 32-Bit Float Audiophile DSP Chain + Pre-Volume Spectrum Tap
            dsp.process_interleaved(out, &params, |mono| {
                tap.push(mono);
            });
        });

        let output = NativeAudioOutput::open(render, needs_reopen)?;
        self.shared
            .output_sample_rate
            .store(output.sample_rate, Ordering::Release);
        self.shared.needs_reopen.store(false, Ordering::Release);
        self.output = Some(output);
        Ok(())
    }

    fn ensure_stream_healthy(&mut self) {
        if self.shared.needs_reopen.swap(false, Ordering::AcqRel) {
            let was_playing = self.shared.playing.load(Ordering::Acquire);
            let _ = self.open_output_stream();
            if was_playing {
                if let Some(ref out) = self.output {
                    let _ = out.start();
                }
            }
        }
    }

    fn stop_decoder_thread(&mut self) {
        if let Some(tx) = self.decoder_cmd_tx.take() {
            let _ = tx.send(DecoderCommand::Stop);
        }
        if let Some(handle) = self.decoder_thread.take() {
            let _ = handle.join();
        }
    }

    fn clear_ring_buffer(&self) {
        if let Ok(mut cons) = self.consumer_mtx.lock() {
            let avail = cons.occupied_len();
            if avail > 0 {
                cons.skip(avail);
            }
        }
    }

    pub fn load_file(&mut self, path: &str) -> Result<(), String> {
        let dec = AudioDecoder::open_path(path).map_err(|e| {
            self.set_error(&e);
            e
        })?;
        self.start_with_decoder(dec)
    }

    #[cfg(unix)]
    pub fn load_fd(&mut self, fd: i32, ext_hint: Option<&str>) -> Result<(), String> {
        let dec = AudioDecoder::open_raw_fd(fd, ext_hint).map_err(|e| {
            self.set_error(&e);
            e
        })?;
        self.start_with_decoder(dec)
    }

    fn start_with_decoder(&mut self, mut decoder: AudioDecoder) -> Result<(), String> {
        self.ensure_stream_healthy();
        self.shared.playing.store(false, Ordering::Release);
        self.stop_decoder_thread();
        // Synchronously drain stale audio from previous track BEFORE spawning new decoder
        self.clear_ring_buffer();

        // Store metadata & duration
        let dur_ms = (decoder.metadata.duration_sec * 1000.0).round() as u64;
        self.shared.duration_ms.store(dur_ms, Ordering::Release);
        self.shared.position_ms.store(0, Ordering::Release);
        self.shared.decoder_eof.store(false, Ordering::Release);
        self.shared.eos_triggered.store(false, Ordering::Release);
        self.shared.reset_dsp_only.store(true, Ordering::Release);
        self.shared.tap.clear();

        if let Ok(mut meta) = self.metadata.lock() {
            *meta = decoder.metadata.clone();
        }
        self.set_error("");

        let (tx, rx) = std::sync::mpsc::channel::<DecoderCommand>();
        self.decoder_cmd_tx = Some(tx);

        let producer_slot = Arc::clone(&self.producer_slot);
        let consumer_mtx = Arc::clone(&self.consumer_mtx);
        let decoder_eof = Arc::clone(&self.shared.decoder_eof);
        let out_sr = Arc::clone(&self.shared.output_sample_rate);
        let reset_dsp_only = Arc::clone(&self.shared.reset_dsp_only);
        let position_ms = Arc::clone(&self.shared.position_ms);

        let thread = thread::spawn(move || {
            let mut prod = match producer_slot.lock().unwrap().take() {
                Some(p) => p,
                None => return,
            };

            let mut scratch = vec![0.0_f32; 2048 * 2]; // 2048 stereo frames per chunk
            let mut pending_offset = 0usize;
            let mut pending_len = 0usize;

            loop {
                // Process any control commands immediately
                let mut should_stop = false;
                while let Ok(cmd) = rx.try_recv() {
                    match cmd {
                        DecoderCommand::Stop => {
                            should_stop = true;
                            break;
                        }
                        DecoderCommand::Seek(sec) => {
                            if decoder.seek_seconds(sec).is_ok() {
                                pending_offset = 0;
                                pending_len = 0;
                                if let Ok(mut cons) = consumer_mtx.lock() {
                                    let avail = cons.occupied_len();
                                    if avail > 0 {
                                        cons.skip(avail);
                                    }
                                }
                                decoder_eof.store(false, Ordering::Release);
                                let pos = (decoder.current_position_sec() * 1000.0).round() as u64;
                                position_ms.store(pos, Ordering::Release);
                                reset_dsp_only.store(true, Ordering::Release);
                            }
                        }
                    }
                }
                if should_stop {
                    break;
                }

                // Drain any pending decoded samples into ring buffer
                if pending_offset < pending_len {
                    let pushed = prod.push_slice(&scratch[pending_offset..pending_len]);
                    pending_offset += pushed;
                    if pending_offset < pending_len {
                        thread::sleep(Duration::from_millis(4));
                        continue;
                    }
                }

                // Wait if ring buffer is sufficiently full
                if prod.vacant_len() < 4096 {
                    thread::sleep(Duration::from_millis(4));
                    continue;
                }

                // If we already hit EOF, wait for Seek or Stop command
                if decoder_eof.load(Ordering::Acquire) {
                    match rx.recv_timeout(Duration::from_millis(25)) {
                        Ok(DecoderCommand::Stop) => break,
                        Ok(DecoderCommand::Seek(sec)) => {
                            if decoder.seek_seconds(sec).is_ok() {
                                if let Ok(mut cons) = consumer_mtx.lock() {
                                    let avail = cons.occupied_len();
                                    if avail > 0 {
                                        cons.skip(avail);
                                    }
                                }
                                decoder_eof.store(false, Ordering::Release);
                                let pos = (decoder.current_position_sec() * 1000.0).round() as u64;
                                position_ms.store(pos, Ordering::Release);
                                reset_dsp_only.store(true, Ordering::Release);
                            }
                        }
                        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => continue,
                        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break,
                    }
                    continue;
                }

                let sr = out_sr.load(Ordering::Relaxed).max(8000);
                match decoder.read_resampled_stereo(&mut scratch, sr) {
                    Ok(0) => {
                        decoder_eof.store(true, Ordering::Release);
                    }
                    Ok(frames) => {
                        pending_offset = 0;
                        pending_len = frames * 2;
                    }
                    Err(_) => {
                        decoder_eof.store(true, Ordering::Release);
                    }
                }
            }

            // Return producer cleanly for the next loaded track!
            *producer_slot.lock().unwrap() = Some(prod);
        });

        self.decoder_thread = Some(thread);

        // Give decoder ~15ms head-start to prefill ring buffer so playback begins click-free
        thread::sleep(Duration::from_millis(15));
        self.play()
    }

    pub fn play(&mut self) -> Result<(), String> {
        self.ensure_stream_healthy();
        self.shared.eos_triggered.store(false, Ordering::Release);
        self.shared.playing.store(true, Ordering::Release);

        let first_try = match self.output {
            Some(ref out) => out.start(),
            None => Err("No audio output stream".to_string()),
        };

        if first_try.is_ok() {
            return Ok(());
        }

        // Seamless automatic recovery if AAudio stream became disconnected or stale
        self.open_output_stream().map_err(|e| {
            self.set_error(&e);
            e
        })?;
        if let Some(ref out) = self.output {
            out.start().map_err(|e| {
                self.set_error(&e);
                e
            })?;
        }
        Ok(())
    }

    pub fn pause(&mut self) {
        self.shared.playing.store(false, Ordering::Release);
        if let Some(ref out) = self.output {
            out.pause();
        }
    }

    pub fn stop(&mut self) {
        self.shared.playing.store(false, Ordering::Release);
        if let Some(ref out) = self.output {
            out.stop();
        }
        self.stop_decoder_thread();
        self.clear_ring_buffer();
        self.shared.reset_dsp_only.store(true, Ordering::Release);
        self.shared.position_ms.store(0, Ordering::Release);
        self.shared.duration_ms.store(0, Ordering::Release);
        self.shared.decoder_eof.store(false, Ordering::Release);
        self.shared.eos_triggered.store(false, Ordering::Release);
        self.shared.tap.clear();
        if let Ok(mut meta) = self.metadata.lock() {
            *meta = TrackMetadata::default();
        }
    }

    pub fn is_playing(&self) -> bool {
        self.shared.playing.load(Ordering::Acquire)
    }

    pub fn take_ended(&self) -> bool {
        self.shared.eos_triggered.swap(false, Ordering::AcqRel)
    }

    pub fn get_position(&self) -> f64 {
        self.shared.position_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn get_duration(&self) -> f64 {
        self.shared.duration_ms.load(Ordering::Relaxed) as f64 / 1000.0
    }

    pub fn seek(&mut self, seconds: f64) -> Result<(), String> {
        if !seconds.is_finite() || seconds < 0.0 {
            return Err(format!("Invalid seek position: {seconds}"));
        }
        if let Some(ref tx) = self.decoder_cmd_tx {
            let ms = (seconds * 1000.0).round() as u64;
            self.shared.position_ms.store(ms, Ordering::Relaxed);
            self.shared.eos_triggered.store(false, Ordering::Release);
            tx.send(DecoderCommand::Seek(seconds))
                .map_err(|_| "Decoder thread not active".to_string())?;
        }
        Ok(())
    }

    pub fn poll_spectrum(
        &self,
        out_bars: &mut [f32; SPECTRUM_BARS],
        out_peaks: &mut [f32; SPECTRUM_BARS],
    ) {
        if let Ok(mut spec) = self.spectrum.lock() {
            spec.update(&self.shared.tap, self.is_playing());
            out_bars.copy_from_slice(&spec.bars);
            out_peaks.copy_from_slice(&spec.peaks);
        }
    }

    pub fn metadata_json(&self) -> String {
        let meta = self.metadata.lock().map(|m| m.clone()).unwrap_or_default();
        let title = json_opt(&meta.title);
        let artist = json_opt(&meta.artist);
        let album = json_opt(&meta.album);
        format!(
            "{{\"title\":{title},\"artist\":{artist},\"album\":{album},\"sample_rate\":{},\"duration_sec\":{:.3}}}",
            meta.sample_rate, meta.duration_sec
        )
    }

    pub fn last_error(&self) -> String {
        self.last_error
            .lock()
            .map(|e| e.clone())
            .unwrap_or_default()
    }

    fn set_error(&self, msg: &str) {
        if let Ok(mut e) = self.last_error.lock() {
            *e = msg.to_string();
        }
    }
}

impl Drop for AudioEngineV10 {
    fn drop(&mut self) {
        self.stop();
        self.output = None;
    }
}

fn json_opt(opt: &Option<String>) -> String {
    match opt {
        None => "null".to_string(),
        Some(s) => {
            let mut out = String::with_capacity(s.len() + 2);
            out.push('"');
            for ch in s.chars() {
                match ch {
                    '"' => out.push_str("\\\""),
                    '\\' => out.push_str("\\\\"),
                    '\n' => out.push_str("\\n"),
                    '\r' => out.push_str("\\r"),
                    '\t' => out.push_str("\\t"),
                    c if (c as u32) < 0x20 => {}
                    c => out.push(c),
                }
            }
            out.push('"');
            out
        }
    }
}

fn write_str_to_buf(s: &str, buf: *mut u8, buf_len: usize) -> i32 {
    if buf.is_null() || buf_len == 0 {
        return 0;
    }
    let bytes = s.as_bytes();
    let n = bytes.len().min(buf_len.saturating_sub(1));
    unsafe {
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), buf, n);
        *buf.add(n) = 0;
    }
    n as i32
}

// ============================================================================
// C ABI Exports for Dart FFI (`libaudio_engine_v10.so`)
// ============================================================================

#[no_mangle]
pub extern "C" fn ae_create() -> *mut AudioEngineV10 {
    match AudioEngineV10::new() {
        Ok(engine) => Box::into_raw(Box::new(engine)),
        Err(_) => std::ptr::null_mut(),
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_destroy(handle: *mut AudioEngineV10) {
    if !handle.is_null() {
        drop(Box::from_raw(handle));
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_load_file(
    handle: *mut AudioEngineV10,
    path_utf8: *const c_char,
) -> i32 {
    if handle.is_null() || path_utf8.is_null() {
        return -1;
    }
    let engine = &mut *handle;
    let Ok(path) = CStr::from_ptr(path_utf8).to_str() else {
        engine.set_error("Invalid UTF-8 file path");
        return -2;
    };
    match engine.load_file(path) {
        Ok(()) => 0,
        Err(_) => -3,
    }
}

#[cfg(unix)]
#[no_mangle]
pub unsafe extern "C" fn ae_load_fd(
    handle: *mut AudioEngineV10,
    fd: i32,
    ext_utf8: *const c_char,
) -> i32 {
    if handle.is_null() {
        return -1;
    }
    let engine = &mut *handle;
    let ext = if ext_utf8.is_null() {
        None
    } else {
        CStr::from_ptr(ext_utf8).to_str().ok()
    };
    match engine.load_fd(fd, ext) {
        Ok(()) => 0,
        Err(_) => -3,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_play(handle: *mut AudioEngineV10) -> i32 {
    if handle.is_null() {
        return -1;
    }
    match (*handle).play() {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_pause(handle: *mut AudioEngineV10) {
    if !handle.is_null() {
        (*handle).pause();
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_stop(handle: *mut AudioEngineV10) {
    if !handle.is_null() {
        (*handle).stop();
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_is_playing(handle: *mut AudioEngineV10) -> i32 {
    if handle.is_null() {
        return 0;
    }
    i32::from((*handle).is_playing())
}

#[no_mangle]
pub unsafe extern "C" fn ae_take_ended(handle: *mut AudioEngineV10) -> i32 {
    if handle.is_null() {
        return 0;
    }
    i32::from((*handle).take_ended())
}

#[no_mangle]
pub unsafe extern "C" fn ae_get_position(handle: *mut AudioEngineV10) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    (*handle).get_position()
}

#[no_mangle]
pub unsafe extern "C" fn ae_get_duration(handle: *mut AudioEngineV10) -> f64 {
    if handle.is_null() {
        return 0.0;
    }
    (*handle).get_duration()
}

#[no_mangle]
pub unsafe extern "C" fn ae_seek(handle: *mut AudioEngineV10, sec: f64) -> i32 {
    if handle.is_null() {
        return -1;
    }
    match (*handle).seek(sec) {
        Ok(()) => 0,
        Err(_) => -1,
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_volume(handle: *mut AudioEngineV10, volume: f64) {
    if !handle.is_null() {
        (*handle).shared.params.set_volume(volume);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_mute(handle: *mut AudioEngineV10, muted: i32) {
    if !handle.is_null() {
        (*handle).shared.params.set_muted(muted != 0);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_balance(handle: *mut AudioEngineV10, pan: f32) {
    if !handle.is_null() {
        (*handle).shared.params.set_balance(pan);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_eq_band(handle: *mut AudioEngineV10, band: u32, gain_db: f64) {
    if !handle.is_null() {
        (*handle).shared.params.set_eq_band(band as usize, gain_db);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_all_eq_bands(handle: *mut AudioEngineV10, gains_ptr: *const f64) {
    if handle.is_null() || gains_ptr.is_null() {
        return;
    }
    let slice = std::slice::from_raw_parts(gains_ptr, 10);
    let mut arr = [0.0_f64; 10];
    arr.copy_from_slice(slice);
    (*handle).shared.params.set_all_eq_bands(&arr);
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_auto_headroom(handle: *mut AudioEngineV10, enabled: i32) {
    if !handle.is_null() {
        (*handle).shared.params.set_auto_headroom(enabled != 0);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_stereo_widening(handle: *mut AudioEngineV10, amount: f32) {
    if !handle.is_null() {
        (*handle).shared.params.set_stereo_width(amount);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_punch_enabled(handle: *mut AudioEngineV10, enabled: i32) {
    if !handle.is_null() {
        (*handle).shared.params.set_punch_enabled(enabled != 0);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_set_room_reverb(handle: *mut AudioEngineV10, amount: f32) {
    if !handle.is_null() {
        (*handle).shared.params.set_room_reverb(amount);
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_reset_dsp_effects(handle: *mut AudioEngineV10) {
    if !handle.is_null() {
        (*handle).shared.params.reset_dsp_effects();
    }
}

#[no_mangle]
pub unsafe extern "C" fn ae_poll_spectrum(
    handle: *mut AudioEngineV10,
    out_bars64: *mut f32,
    out_peaks64: *mut f32,
) -> i32 {
    if handle.is_null() || out_bars64.is_null() || out_peaks64.is_null() {
        return -1;
    }
    let mut bars = [0.0_f32; SPECTRUM_BARS];
    let mut peaks = [0.0_f32; SPECTRUM_BARS];
    (*handle).poll_spectrum(&mut bars, &mut peaks);
    std::ptr::copy_nonoverlapping(bars.as_ptr(), out_bars64, SPECTRUM_BARS);
    std::ptr::copy_nonoverlapping(peaks.as_ptr(), out_peaks64, SPECTRUM_BARS);
    SPECTRUM_BARS as i32
}

#[no_mangle]
pub unsafe extern "C" fn ae_get_metadata_json(
    handle: *mut AudioEngineV10,
    buf: *mut u8,
    buf_len: usize,
) -> i32 {
    if handle.is_null() {
        return 0;
    }
    let json = (*handle).metadata_json();
    write_str_to_buf(&json, buf, buf_len)
}

#[no_mangle]
pub unsafe extern "C" fn ae_get_last_error(
    handle: *mut AudioEngineV10,
    buf: *mut u8,
    buf_len: usize,
) -> i32 {
    if handle.is_null() {
        return 0;
    }
    let err = (*handle).last_error();
    write_str_to_buf(&err, buf, buf_len)
}

// ============================================================================
// Unit Tests — Verify Pure 32-Bit Float DSP Chain, Limiter, FFT & WAV Playback
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::PI;

    #[test]
    fn dsp_chain_eq_spatial_punch_reverb_limiter_clean() {
        let params = DspParams::new();
        params.set_volume(1.5); // 150% max boost to verify peak limiter ceiling!
        params.set_all_eq_bands(&[7.65, 5.85, 3.15, 2.0, 1.0, 0.0, 0.0, 2.0, 2.5, 0.0]);
        params.set_auto_headroom(true);
        params.set_stereo_width(0.65);
        params.set_punch_enabled(true);
        params.set_room_reverb(0.45);

        let mut dsp = DspChain::new(48000);
        let tap = SpectrumTap::new();
        let mut analyzer = SpectrumAnalyzer::new();

        // Generate 4096 stereo frames of a rich 220Hz + 1000Hz + 4400Hz signal
        let mut buf = vec![0.0_f32; 4096 * 2];
        for i in 0..4096 {
            let t = i as f32 / 48000.0;
            let l = 0.45 * (2.0 * PI * 220.0 * t).sin() + 0.3 * (2.0 * PI * 1000.0 * t).sin();
            let r = 0.45 * (2.0 * PI * 220.0 * t).sin() + 0.3 * (2.0 * PI * 4400.0 * t).sin();
            buf[i * 2] = l;
            buf[i * 2 + 1] = r;
        }

        dsp.process_interleaved(&mut buf, &params, |m| tap.push(m));

        // Verify every single sample is finite and safely clamped by peak limiter
        for &s in &buf {
            assert!(s.is_finite(), "Non-finite sample in DSP output!");
            assert!(s.abs() <= 1.0, "Sample exceeded 1.0 ceiling: {s}");
        }

        // Verify FFT spectrum lights up on active signal
        analyzer.update(&tap, true);
        let energy: f32 = analyzer.bars.iter().sum();
        assert!(
            energy > 1.0,
            "Expected non-zero RTA spectrum energy, got {energy}"
        );
    }

    #[test]
    fn decoder_plays_generated_wav_and_seeks() {
        // Write a tiny valid 44.1kHz stereo 16-bit WAV (0.5s) to /tmp
        let path = "/tmp/ae_v10_test_tone.wav";
        let sr: u32 = 44100;
        let frames: u32 = sr / 2;
        let data_bytes: u32 = frames * 4;
        let mut wav = Vec::with_capacity((44 + data_bytes) as usize);
        wav.extend_from_slice(b"RIFF");
        wav.extend_from_slice(&(36 + data_bytes).to_le_bytes());
        wav.extend_from_slice(b"WAVEfmt ");
        wav.extend_from_slice(&16u32.to_le_bytes());
        wav.extend_from_slice(&1u16.to_le_bytes()); // PCM
        wav.extend_from_slice(&2u16.to_le_bytes()); // Stereo
        wav.extend_from_slice(&sr.to_le_bytes());
        wav.extend_from_slice(&(sr * 4).to_le_bytes());
        wav.extend_from_slice(&4u16.to_le_bytes());
        wav.extend_from_slice(&16u16.to_le_bytes());
        wav.extend_from_slice(b"data");
        wav.extend_from_slice(&data_bytes.to_le_bytes());
        for i in 0..frames {
            let t = i as f32 / sr as f32;
            let sample = ((2.0 * PI * 440.0 * t).sin() * 16000.0) as i16;
            wav.extend_from_slice(&sample.to_le_bytes());
            wav.extend_from_slice(&sample.to_le_bytes());
        }
        std::fs::write(path, &wav).expect("write test wav");

        let mut engine = AudioEngineV10::new().expect("engine create");
        engine.load_file(path).expect("load wav");
        assert!(engine.is_playing());
        assert!((engine.get_duration() - 0.5).abs() < 0.05);

        thread::sleep(Duration::from_millis(60));
        let mut bars = [0.0_f32; SPECTRUM_BARS];
        let mut peaks = [0.0_f32; SPECTRUM_BARS];
        engine.poll_spectrum(&mut bars, &mut peaks);
        assert!(
            bars.iter().any(|&b| b > 0.01),
            "Spectrum should react to WAV tone"
        );

        engine.seek(0.25).expect("seek should succeed");
        engine.pause();
        assert!(!engine.is_playing());
        engine.stop();
        let _ = std::fs::remove_file(path);
    }
}
