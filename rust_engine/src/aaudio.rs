// ============================================================================
// aaudio.rs — Cross-Platform Native 32-Bit Float (F32LE) Audio Output
//   • Android: Direct NDK libaaudio.so (AAUDIO_FORMAT_PCM_FLOAT, Low-Latency)
//   • Linux Desktop: Direct libpulse-simple.so.0 (PA_SAMPLE_FLOAT32LE -> PipeWire/PA)
//   • Tests: Headless host stub for `cargo test`
// ============================================================================

#[cfg(target_os = "android")]
mod android_impl {
    use std::ffi::c_void;
    use std::ptr;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;

    #[repr(C)]
    pub struct AAudioStreamBuilder {
        _private: [u8; 0],
    }

    #[repr(C)]
    pub struct AAudioStream {
        _private: [u8; 0],
    }

    pub type AAudioResult = i32;
    pub type AAudioStreamState = i32;
    pub type AAudioDataCallbackResult = i32;

    pub const AAUDIO_OK: AAudioResult = 0;
    pub const AAUDIO_DIRECTION_OUTPUT: i32 = 0;
    pub const AAUDIO_FORMAT_PCM_FLOAT: i32 = 2;
    pub const AAUDIO_SHARING_MODE_SHARED: i32 = 1;
    pub const AAUDIO_PERFORMANCE_MODE_LOW_LATENCY: i32 = 12;
    pub const AAUDIO_USAGE_MEDIA: i32 = 1;
    pub const AAUDIO_CONTENT_TYPE_MUSIC: i32 = 2;
    pub const AAUDIO_CALLBACK_RESULT_CONTINUE: AAudioDataCallbackResult = 0;

    pub const AAUDIO_STREAM_STATE_STARTING: AAudioStreamState = 3;
    pub const AAUDIO_STREAM_STATE_STARTED: AAudioStreamState = 4;
    pub const AAUDIO_STREAM_STATE_STOPPING: AAudioStreamState = 9;
    pub const AAUDIO_STREAM_STATE_STOPPED: AAudioStreamState = 10;
    pub const AAUDIO_STREAM_STATE_CLOSING: AAudioStreamState = 11;
    pub const AAUDIO_STREAM_STATE_CLOSED: AAudioStreamState = 12;
    pub const AAUDIO_STREAM_STATE_DISCONNECTED: AAudioStreamState = 13;

    type DataCallbackFn = extern "C" fn(
        stream: *mut AAudioStream,
        user_data: *mut c_void,
        audio_data: *mut c_void,
        num_frames: i32,
    ) -> AAudioDataCallbackResult;

    type ErrorCallbackFn = extern "C" fn(
        stream: *mut AAudioStream,
        user_data: *mut c_void,
        error: AAudioResult,
    );

    #[link(name = "aaudio")]
    extern "C" {
        fn AAudio_createStreamBuilder(builder: *mut *mut AAudioStreamBuilder) -> AAudioResult;
        fn AAudioStreamBuilder_delete(builder: *mut AAudioStreamBuilder) -> AAudioResult;
        fn AAudioStreamBuilder_setDirection(builder: *mut AAudioStreamBuilder, direction: i32);
        fn AAudioStreamBuilder_setChannelCount(builder: *mut AAudioStreamBuilder, channel_count: i32);
        fn AAudioStreamBuilder_setFormat(builder: *mut AAudioStreamBuilder, format: i32);
        fn AAudioStreamBuilder_setSharingMode(builder: *mut AAudioStreamBuilder, sharing_mode: i32);
        fn AAudioStreamBuilder_setPerformanceMode(builder: *mut AAudioStreamBuilder, mode: i32);
        fn AAudioStreamBuilder_setUsage(builder: *mut AAudioStreamBuilder, usage: i32);
        fn AAudioStreamBuilder_setContentType(builder: *mut AAudioStreamBuilder, content_type: i32);
        fn AAudioStreamBuilder_setDataCallback(
            builder: *mut AAudioStreamBuilder,
            callback: DataCallbackFn,
            user_data: *mut c_void,
        );
        fn AAudioStreamBuilder_setErrorCallback(
            builder: *mut AAudioStreamBuilder,
            callback: ErrorCallbackFn,
            user_data: *mut c_void,
        );
        fn AAudioStreamBuilder_openStream(
            builder: *mut AAudioStreamBuilder,
            stream: *mut *mut AAudioStream,
        ) -> AAudioResult;
        fn AAudioStream_getSampleRate(stream: *mut AAudioStream) -> i32;
        fn AAudioStream_getState(stream: *mut AAudioStream) -> AAudioStreamState;
        fn AAudioStream_requestStart(stream: *mut AAudioStream) -> AAudioResult;
        fn AAudioStream_requestPause(stream: *mut AAudioStream) -> AAudioResult;
        fn AAudioStream_requestStop(stream: *mut AAudioStream) -> AAudioResult;
        fn AAudioStream_close(stream: *mut AAudioStream) -> AAudioResult;
    }

    pub struct CallbackBox {
        pub render: Box<dyn FnMut(&mut [f32]) + Send>,
        pub needs_reopen: Arc<AtomicBool>,
    }

    extern "C" fn data_cb(
        _stream: *mut AAudioStream,
        user_data: *mut c_void,
        audio_data: *mut c_void,
        num_frames: i32,
    ) -> AAudioDataCallbackResult {
        if user_data.is_null() || audio_data.is_null() || num_frames <= 0 {
            return AAUDIO_CALLBACK_RESULT_CONTINUE;
        }
        unsafe {
            let cb = &mut *(user_data as *mut CallbackBox);
            let slice = std::slice::from_raw_parts_mut(
                audio_data as *mut f32,
                (num_frames as usize) * 2,
            );
            (cb.render)(slice);
        }
        AAUDIO_CALLBACK_RESULT_CONTINUE
    }

    extern "C" fn error_cb(
        _stream: *mut AAudioStream,
        user_data: *mut c_void,
        _error: AAudioResult,
    ) {
        if !user_data.is_null() {
            unsafe {
                let cb = &*(user_data as *const CallbackBox);
                cb.needs_reopen.store(true, Ordering::Release);
            }
        }
    }

    pub struct NativeAudioOutput {
        stream: *mut AAudioStream,
        cb_ptr: *mut CallbackBox,
        pub sample_rate: u32,
    }

    unsafe impl Send for NativeAudioOutput {}

    impl NativeAudioOutput {
        pub fn open(
            render: Box<dyn FnMut(&mut [f32]) + Send>,
            needs_reopen: Arc<AtomicBool>,
        ) -> Result<Self, String> {
            unsafe {
                let mut builder: *mut AAudioStreamBuilder = ptr::null_mut();
                let res = AAudio_createStreamBuilder(&mut builder);
                if res != AAUDIO_OK || builder.is_null() {
                    return Err(format!("AAudio_createStreamBuilder failed: {res}"));
                }

                let cb_box = Box::new(CallbackBox {
                    render,
                    needs_reopen,
                });
                let cb_ptr = Box::into_raw(cb_box);

                AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
                AAudioStreamBuilder_setChannelCount(builder, 2);
                AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_FLOAT);
                AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_SHARED);
                AAudioStreamBuilder_setPerformanceMode(builder, AAUDIO_PERFORMANCE_MODE_LOW_LATENCY);
                AAudioStreamBuilder_setUsage(builder, AAUDIO_USAGE_MEDIA);
                AAudioStreamBuilder_setContentType(builder, AAUDIO_CONTENT_TYPE_MUSIC);
                AAudioStreamBuilder_setDataCallback(builder, data_cb, cb_ptr as *mut c_void);
                AAudioStreamBuilder_setErrorCallback(builder, error_cb, cb_ptr as *mut c_void);

                let mut stream: *mut AAudioStream = ptr::null_mut();
                let open_res = AAudioStreamBuilder_openStream(builder, &mut stream);
                AAudioStreamBuilder_delete(builder);

                if open_res != AAUDIO_OK || stream.is_null() {
                    drop(Box::from_raw(cb_ptr));
                    return Err(format!("AAudioStreamBuilder_openStream failed: {open_res}"));
                }

                let sr = AAudioStream_getSampleRate(stream).max(8000) as u32;
                Ok(Self {
                    stream,
                    cb_ptr,
                    sample_rate: sr,
                })
            }
        }

        pub fn start(&self) -> Result<(), String> {
            unsafe {
                let state = AAudioStream_getState(self.stream);
                if state == AAUDIO_STREAM_STATE_STARTING || state == AAUDIO_STREAM_STATE_STARTED {
                    return Ok(());
                }
                if state == AAUDIO_STREAM_STATE_DISCONNECTED
                    || state == AAUDIO_STREAM_STATE_CLOSING
                    || state == AAUDIO_STREAM_STATE_CLOSED
                {
                    return Err(format!("AAudio stream disconnected (state {state})"));
                }
                let res = AAudioStream_requestStart(self.stream);
                if res == AAUDIO_OK {
                    Ok(())
                } else {
                    Err(format!("AAudio requestStart failed: {res}"))
                }
            }
        }

        pub fn pause(&self) {
            unsafe {
                let state = AAudioStream_getState(self.stream);
                if state == AAUDIO_STREAM_STATE_STARTING || state == AAUDIO_STREAM_STATE_STARTED {
                    let _ = AAudioStream_requestPause(self.stream);
                }
            }
        }

        pub fn stop(&self) {
            unsafe {
                let state = AAudioStream_getState(self.stream);
                if state != AAUDIO_STREAM_STATE_STOPPING
                    && state != AAUDIO_STREAM_STATE_STOPPED
                    && state != AAUDIO_STREAM_STATE_CLOSING
                    && state != AAUDIO_STREAM_STATE_CLOSED
                    && state != AAUDIO_STREAM_STATE_DISCONNECTED
                {
                    let _ = AAudioStream_requestStop(self.stream);
                }
            }
        }
    }

    impl Drop for NativeAudioOutput {
        fn drop(&mut self) {
            unsafe {
                if !self.stream.is_null() {
                    let _ = AAudioStream_requestStop(self.stream);
                    let _ = AAudioStream_close(self.stream);
                    self.stream = ptr::null_mut();
                }
                if !self.cb_ptr.is_null() {
                    drop(Box::from_raw(self.cb_ptr));
                    self.cb_ptr = ptr::null_mut();
                }
            }
        }
    }
}

#[cfg(all(target_os = "linux", not(test)))]
mod linux_pulse_impl {
    use std::ffi::{c_char, c_int, c_void, CString};
    use std::ptr;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread::{self, JoinHandle};
    use std::time::Duration;

    #[repr(C)]
    struct PaSimple {
        _private: [u8; 0],
    }

    #[repr(C)]
    struct PaSampleSpec {
        format: i32,
        rate: u32,
        channels: u8,
    }

    #[repr(C)]
    struct PaBufferAttr {
        maxlength: u32,
        tlength: u32,
        prebuf: u32,
        minreq: u32,
        fragsize: u32,
    }

    const PA_STREAM_PLAYBACK: i32 = 1;
    const PA_SAMPLE_FLOAT32LE: i32 = 5;

    #[link(name = "pulse-simple")]
    extern "C" {
        fn pa_simple_new(
            server: *const c_char,
            name: *const c_char,
            dir: i32,
            dev: *const c_char,
            stream_name: *const c_char,
            ss: *const PaSampleSpec,
            map: *const c_void,
            attr: *const PaBufferAttr,
            error: *mut c_int,
        ) -> *mut PaSimple;
        fn pa_simple_write(
            s: *mut PaSimple,
            data: *const c_void,
            bytes: usize,
            error: *mut c_int,
        ) -> c_int;
        fn pa_simple_flush(s: *mut PaSimple, error: *mut c_int) -> c_int;
        fn pa_simple_free(s: *mut PaSimple);
    }

    /// Native Linux 32-Bit Float (`PA_SAMPLE_FLOAT32LE`) playback via PipeWire/PulseAudio.
    pub struct NativeAudioOutput {
        running: Arc<AtomicBool>,
        active: Arc<AtomicBool>,
        flush_req: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
        pub sample_rate: u32,
    }

    impl NativeAudioOutput {
        pub fn open(
            mut render: Box<dyn FnMut(&mut [f32]) + Send>,
            _needs_reopen: Arc<AtomicBool>,
        ) -> Result<Self, String> {
            let sr: u32 = 48000;
            let running = Arc::new(AtomicBool::new(true));
            let active = Arc::new(AtomicBool::new(false));
            let flush_req = Arc::new(AtomicBool::new(false));

            let r_cl = Arc::clone(&running);
            let a_cl = Arc::clone(&active);
            let f_cl = Arc::clone(&flush_req);

            let thread = thread::spawn(move || {
                let app_name = CString::new("Audio Engine V10").unwrap();
                let stream_name = CString::new("32-Bit Float Audiophile DSP").unwrap();
                let ss = PaSampleSpec {
                    format: PA_SAMPLE_FLOAT32LE,
                    rate: sr,
                    channels: 2,
                };
                // ~40ms target latency for rock-solid, glitch-free playback on PipeWire/Pulse
                let frame_bytes = 2 * std::mem::size_of::<f32>() as u32;
                let tlength = (sr / 25) * frame_bytes;
                let attr = PaBufferAttr {
                    maxlength: u32::MAX,
                    tlength,
                    prebuf: u32::MAX,
                    minreq: u32::MAX,
                    fragsize: u32::MAX,
                };

                let mut pa: *mut PaSimple = ptr::null_mut();
                let mut buf = vec![0.0_f32; 960 * 2]; // 20ms stereo f32 @ 48kHz

                while r_cl.load(Ordering::Relaxed) {
                    if f_cl.swap(false, Ordering::AcqRel) && !pa.is_null() {
                        let mut err: c_int = 0;
                        unsafe {
                            pa_simple_flush(pa, &mut err);
                        }
                    }

                    if !a_cl.load(Ordering::Acquire) {
                        // Close PipeWire stream while idle so we don't hold audio focus when paused
                        if !pa.is_null() {
                            unsafe {
                                pa_simple_free(pa);
                            }
                            pa = ptr::null_mut();
                        }
                        thread::sleep(Duration::from_millis(12));
                        continue;
                    }

                    if pa.is_null() {
                        let mut err: c_int = 0;
                        pa = unsafe {
                            pa_simple_new(
                                ptr::null(),
                                app_name.as_ptr(),
                                PA_STREAM_PLAYBACK,
                                ptr::null(),
                                stream_name.as_ptr(),
                                &ss,
                                ptr::null(),
                                &attr,
                                &mut err,
                            )
                        };
                        if pa.is_null() {
                            thread::sleep(Duration::from_millis(50));
                            continue;
                        }
                    }

                    render(&mut buf);
                    let mut err: c_int = 0;
                    let bytes = buf.len() * std::mem::size_of::<f32>();
                    let ok = unsafe {
                        pa_simple_write(pa, buf.as_ptr() as *const c_void, bytes, &mut err)
                    };
                    if ok < 0 {
                        unsafe {
                            pa_simple_free(pa);
                        }
                        pa = ptr::null_mut();
                        thread::sleep(Duration::from_millis(20));
                    }
                }

                if !pa.is_null() {
                    unsafe {
                        pa_simple_free(pa);
                    }
                }
            });

            Ok(Self {
                running,
                active,
                flush_req,
                thread: Some(thread),
                sample_rate: sr,
            })
        }

        pub fn start(&self) -> Result<(), String> {
            self.active.store(true, Ordering::Release);
            Ok(())
        }

        pub fn pause(&self) {
            self.active.store(false, Ordering::Release);
            self.flush_req.store(true, Ordering::Release);
        }

        pub fn stop(&self) {
            self.active.store(false, Ordering::Release);
            self.flush_req.store(true, Ordering::Release);
        }
    }

    impl Drop for NativeAudioOutput {
        fn drop(&mut self) {
            self.running.store(false, Ordering::Release);
            if let Some(h) = self.thread.take() {
                let _ = h.join();
            }
        }
    }
}

#[cfg(any(test, not(any(target_os = "android", target_os = "linux"))))]
mod host_stub {
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::Arc;
    use std::thread::{self, JoinHandle};
    use std::time::Duration;

    /// Headless audio driver stub used for `cargo test`.
    pub struct NativeAudioOutput {
        running: Arc<AtomicBool>,
        active: Arc<AtomicBool>,
        thread: Option<JoinHandle<()>>,
        pub sample_rate: u32,
    }

    impl NativeAudioOutput {
        pub fn open(
            mut render: Box<dyn FnMut(&mut [f32]) + Send>,
            _needs_reopen: Arc<AtomicBool>,
        ) -> Result<Self, String> {
            let running = Arc::new(AtomicBool::new(true));
            let active = Arc::new(AtomicBool::new(false));
            let r_clone = Arc::clone(&running);
            let a_clone = Arc::clone(&active);

            let thread = thread::spawn(move || {
                let mut buf = vec![0.0_f32; 960 * 2];
                while r_clone.load(Ordering::Relaxed) {
                    if a_clone.load(Ordering::Relaxed) {
                        render(&mut buf);
                    }
                    thread::sleep(Duration::from_millis(10));
                }
            });

            Ok(Self {
                running,
                active,
                thread: Some(thread),
                sample_rate: 48000,
            })
        }

        pub fn start(&self) -> Result<(), String> {
            self.active.store(true, Ordering::Release);
            Ok(())
        }

        pub fn pause(&self) {
            self.active.store(false, Ordering::Release);
        }

        pub fn stop(&self) {
            self.active.store(false, Ordering::Release);
        }
    }

    impl Drop for NativeAudioOutput {
        fn drop(&mut self) {
            self.running.store(false, Ordering::Release);
            if let Some(h) = self.thread.take() {
                let _ = h.join();
            }
        }
    }
}

#[cfg(target_os = "android")]
pub use android_impl::NativeAudioOutput;

#[cfg(all(target_os = "linux", not(test)))]
pub use linux_pulse_impl::NativeAudioOutput;

#[cfg(any(test, not(any(target_os = "android", target_os = "linux"))))]
pub use host_stub::NativeAudioOutput;
