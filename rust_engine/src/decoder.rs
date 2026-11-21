// ============================================================================
// decoder.rs — Universal Pure-Rust Symphonia Audio Decoder + Cubic Resampler
// Decodes MP3, FLAC, WAV, OGG/Vorbis, AAC/M4A, ALAC into 32-Bit Float stereo
// ============================================================================

use std::fs::File;
use std::path::Path;

use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{Decoder, DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::{FormatOptions, FormatReader, SeekMode, SeekTo};
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::{MetadataOptions, StandardTagKey};
use symphonia::core::probe::Hint;
use symphonia::core::units::Time;

#[derive(Debug, Clone, Default)]
pub struct TrackMetadata {
    pub title: Option<String>,
    pub artist: Option<String>,
    pub album: Option<String>,
    pub sample_rate: u32,
    pub duration_sec: f64,
}

pub struct AudioDecoder {
    format: Box<dyn FormatReader>,
    decoder: Box<dyn Decoder>,
    track_id: u32,
    source_rate: u32,
    source_channels: usize,
    pub metadata: TrackMetadata,
    // Pending stereo interleaved f32 frames from current decoded packet
    src_buf: Vec<f32>,
    src_frame_pos: f64,
    // Keep last 4 stereo frames for Catmull-Rom cubic interpolation across packet boundaries
    hist: [[f32; 2]; 4],
    hist_primed: bool,
    pub decoded_source_frames: u64,
}

impl AudioDecoder {
    pub fn open_path(path: &str) -> Result<Self, String> {
        let file = File::open(path).map_err(|e| format!("Failed to open '{path}': {e}"))?;
        let mut hint = Hint::new();
        if let Some(ext) = Path::new(path).extension().and_then(|e| e.to_str()) {
            hint.with_extension(ext);
        }
        Self::open_file(file, hint)
    }

    #[cfg(unix)]
    pub fn open_raw_fd(fd: i32, ext_hint: Option<&str>) -> Result<Self, String> {
        use std::os::unix::io::FromRawFd;
        if fd < 0 {
            return Err("Invalid file descriptor".to_string());
        }
        // Safety: caller hands ownership of a detached fd (e.g. from Android ParcelFileDescriptor.detachFd)
        let file = unsafe { File::from_raw_fd(fd) };
        let mut hint = Hint::new();
        if let Some(ext) = ext_hint {
            if !ext.is_empty() {
                hint.with_extension(ext);
            }
        }
        Self::open_file(file, hint)
    }

    fn open_file(file: File, hint: Hint) -> Result<Self, String> {
        let mss = MediaSourceStream::new(Box::new(file), Default::default());
        let mut probed = symphonia::default::get_probe()
            .format(
                &hint,
                mss,
                &FormatOptions {
                    enable_gapless: true,
                    ..Default::default()
                },
                &MetadataOptions::default(),
            )
            .map_err(|e| format!("Unsupported audio format: {e}"))?;

        let mut meta = TrackMetadata::default();
        if let Some(m) = probed.metadata.get() {
            if let Some(rev) = m.current() {
                extract_tags(rev.tags(), &mut meta);
            }
        }
        if let Some(rev) = probed.format.metadata().current() {
            extract_tags(rev.tags(), &mut meta);
        }

        let track = probed
            .format
            .tracks()
            .iter()
            .find(|t| t.codec_params.codec != CODEC_TYPE_NULL)
            .ok_or_else(|| "No decodable audio track found".to_string())?;

        let track_id = track.id;
        let codec_params = track.codec_params.clone();
        let source_rate = codec_params.sample_rate.unwrap_or(44100);
        let source_channels = codec_params.channels.map(|c| c.count()).unwrap_or(2);

        let duration_sec = match (codec_params.n_frames, codec_params.sample_rate) {
            (Some(frames), Some(sr)) if sr > 0 => frames as f64 / sr as f64,
            _ => 0.0,
        };
        meta.sample_rate = source_rate;
        meta.duration_sec = duration_sec;

        let decoder = symphonia::default::get_codecs()
            .make(&codec_params, &DecoderOptions::default())
            .map_err(|e| format!("Failed to initialize codec decoder: {e}"))?;

        Ok(Self {
            format: probed.format,
            decoder,
            track_id,
            source_rate,
            source_channels,
            metadata: meta,
            src_buf: Vec::with_capacity(8192),
            src_frame_pos: 0.0,
            hist: [[0.0; 2]; 4],
            hist_primed: false,
            decoded_source_frames: 0,
        })
    }

    pub fn current_position_sec(&self) -> f64 {
        if self.source_rate == 0 {
            return 0.0;
        }
        let pending_frames = (self.src_buf.len() / 2) as f64 - self.src_frame_pos;
        let played = (self.decoded_source_frames as f64 - pending_frames.max(0.0)).max(0.0);
        played / self.source_rate as f64
    }

    pub fn seek_seconds(&mut self, seconds: f64) -> Result<(), String> {
        let clamped = if self.metadata.duration_sec > 0.0 {
            seconds.clamp(0.0, self.metadata.duration_sec)
        } else {
            seconds.max(0.0)
        };
        let whole = clamped.trunc() as u64;
        let frac = clamped.fract();
        let seeked = self
            .format
            .seek(
                SeekMode::Accurate,
                SeekTo::Time {
                    time: Time::new(whole, frac),
                    track_id: Some(self.track_id),
                },
            )
            .map_err(|e| format!("Seek failed: {e}"))?;

        self.decoder.reset();
        self.src_buf.clear();
        self.src_frame_pos = 0.0;
        self.hist = [[0.0; 2]; 4];
        self.hist_primed = false;
        self.decoded_source_frames = seeked.actual_ts;
        Ok(())
    }

    /// Decodes & resamples into stereo interleaved `f32` at `target_rate`.
    /// Returns `Ok(frames_written)`. Returns `Ok(0)` on clean End-Of-Stream.
    pub fn read_resampled_stereo(
        &mut self,
        out_interleaved: &mut [f32],
        target_rate: u32,
    ) -> Result<usize, String> {
        let max_out_frames = out_interleaved.len() / 2;
        if max_out_frames == 0 {
            return Ok(0);
        }

        let target_rate = target_rate.max(8000);
        let ratio = self.source_rate as f64 / target_rate as f64;
        let mut out_idx = 0;

        while out_idx < max_out_frames {
            let avail_frames = self.src_buf.len() / 2;
            let needed_idx = self.src_frame_pos.floor() as usize + 2;

            if needed_idx >= avail_frames {
                // Compact consumed frames while preserving 4-frame history for cubic interpolation
                let consume = (self.src_frame_pos.floor() as usize).min(avail_frames);
                if consume > 0 {
                    for f in 0..consume {
                        self.hist[0] = self.hist[1];
                        self.hist[1] = self.hist[2];
                        self.hist[2] = self.hist[3];
                        self.hist[3] = [self.src_buf[f * 2], self.src_buf[f * 2 + 1]];
                        self.hist_primed = true;
                    }
                    self.src_buf.drain(0..consume * 2);
                    self.src_frame_pos -= consume as f64;
                }

                if !self.decode_next_packet()? {
                    // Flush remaining tail frames on EOS
                    let rem = self.src_buf.len() / 2;
                    while out_idx < max_out_frames && (self.src_frame_pos as usize) < rem {
                        let i = self.src_frame_pos as usize;
                        out_interleaved[out_idx * 2] = self.src_buf[i * 2];
                        out_interleaved[out_idx * 2 + 1] = self.src_buf[i * 2 + 1];
                        out_idx += 1;
                        self.src_frame_pos += ratio;
                    }
                    break;
                }
                continue;
            }

            if self.source_rate == target_rate && self.src_frame_pos.fract().abs() < 1e-6 {
                // Exact 1:1 bit-perfect copy when hardware DAC matches file sample rate!
                let i = self.src_frame_pos as usize;
                out_interleaved[out_idx * 2] = self.src_buf[i * 2];
                out_interleaved[out_idx * 2 + 1] = self.src_buf[i * 2 + 1];
                out_idx += 1;
                self.src_frame_pos += 1.0;
            } else {
                // Catmull-Rom 4-point cubic spline resampler in 32-bit float
                let idx_i = self.src_frame_pos.floor() as isize;
                let t = (self.src_frame_pos - idx_i as f64) as f32;
                let p0 = self.get_frame_signed(idx_i - 1);
                let p1 = self.get_frame_signed(idx_i);
                let p2 = self.get_frame_signed(idx_i + 1);
                let p3 = self.get_frame_signed(idx_i + 2);

                out_interleaved[out_idx * 2] = catmull_rom(p0[0], p1[0], p2[0], p3[0], t);
                out_interleaved[out_idx * 2 + 1] = catmull_rom(p0[1], p1[1], p2[1], p3[1], t);
                out_idx += 1;
                self.src_frame_pos += ratio;
            }
        }

        Ok(out_idx)
    }

    #[inline(always)]
    fn get_frame_signed(&self, idx: isize) -> [f32; 2] {
        let avail = (self.src_buf.len() / 2) as isize;
        if idx < 0 {
            if self.hist_primed {
                let h_idx = (4 + idx).clamp(0, 3) as usize;
                self.hist[h_idx]
            } else if avail > 0 {
                [self.src_buf[0], self.src_buf[1]]
            } else {
                [0.0, 0.0]
            }
        } else if idx < avail {
            let u = idx as usize;
            [self.src_buf[u * 2], self.src_buf[u * 2 + 1]]
        } else if avail > 0 {
            let last = (avail - 1) as usize;
            [self.src_buf[last * 2], self.src_buf[last * 2 + 1]]
        } else {
            [0.0, 0.0]
        }
    }

    fn decode_next_packet(&mut self) -> Result<bool, String> {
        loop {
            let packet = match self.format.next_packet() {
                Ok(pkt) => pkt,
                Err(SymphoniaError::IoError(err))
                    if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(false);
                }
                Err(SymphoniaError::ResetRequired) => {
                    self.decoder.reset();
                    continue;
                }
                Err(e) => return Err(format!("Stream read error: {e}")),
            };

            if packet.track_id() != self.track_id {
                continue;
            }

            let decoded = match self.decoder.decode(&packet) {
                Ok(buf) => buf,
                Err(SymphoniaError::DecodeError(_)) => continue, // skip corrupt frame gracefully
                Err(SymphoniaError::IoError(err))
                    if err.kind() == std::io::ErrorKind::UnexpectedEof =>
                {
                    return Ok(false);
                }
                Err(e) => return Err(format!("Decode error: {e}")),
            };

            let spec = *decoded.spec();
            let channels = spec.channels.count().max(1);
            let frames = decoded.frames();
            if frames == 0 {
                continue;
            }
            self.source_rate = spec.rate;
            self.source_channels = channels;

            let mut sample_buf = SampleBuffer::<f32>::new(decoded.capacity() as u64, spec);
            sample_buf.copy_interleaved_ref(decoded);
            let samples = sample_buf.samples();

            self.src_buf.reserve(frames * 2);
            if channels == 2 {
                self.src_buf.extend_from_slice(&samples[..frames * 2]);
            } else if channels == 1 {
                for &s in &samples[..frames] {
                    self.src_buf.push(s);
                    self.src_buf.push(s);
                }
            } else {
                // Multi-channel downmix to stereo (L/R + center fold)
                for chunk in samples[..frames * channels].chunks_exact(channels) {
                    let mut l = chunk[0];
                    let mut r = chunk[1];
                    if channels >= 3 {
                        let c = chunk[2] * 0.7071;
                        l += c;
                        r += c;
                    }
                    self.src_buf.push(l);
                    self.src_buf.push(r);
                }
            }

            self.decoded_source_frames += frames as u64;
            return Ok(true);
        }
    }
}

#[inline(always)]
fn catmull_rom(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
    let t2 = t * t;
    let t3 = t2 * t;
    0.5 * ((2.0 * p1)
        + (-p0 + p2) * t
        + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
}

fn extract_tags(tags: &[symphonia::core::meta::Tag], meta: &mut TrackMetadata) {
    for tag in tags {
        match tag.std_key {
            Some(StandardTagKey::TrackTitle) if meta.title.is_none() => {
                let s = tag.value.to_string().trim().to_string();
                if !s.is_empty() {
                    meta.title = Some(s);
                }
            }
            Some(StandardTagKey::Artist) | Some(StandardTagKey::AlbumArtist)
                if meta.artist.is_none() =>
            {
                let s = tag.value.to_string().trim().to_string();
                if !s.is_empty() {
                    meta.artist = Some(s);
                }
            }
            Some(StandardTagKey::Album) if meta.album.is_none() => {
                let s = tag.value.to_string().trim().to_string();
                if !s.is_empty() {
                    meta.album = Some(s);
                }
            }
            _ => {}
        }
    }
}
