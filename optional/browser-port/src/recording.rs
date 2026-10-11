//! Continuous native Page.screencastFrame consumer. No captureScreenshot calls.
//! A separate CDP connection drains/acknowledges frames while the port owner
//! performs actions or sleeps. The encoder retains at most the latest image;
//! unchanged content is held at its real elapsed time, never time-compressed.
use super::*;
use base64::{engine::general_purpose::STANDARD, Engine};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    mpsc, Arc, Mutex,
};

pub struct Recording {
    stop: Arc<AtomicBool>,
    frames: Arc<AtomicU64>,
    started: Instant,
    path: PathBuf,
    reader: Option<thread::JoinHandle<Result<()>>>,
    encoder: Option<thread::JoinHandle<Result<u64>>>,
}

fn call(
    ws: &mut WebSocket<MaybeTlsStream<TcpStream>>,
    id: u64,
    method: &str,
    params: Value,
    session: Option<&str>,
) -> Result<Value> {
    let mut request = json!({"id":id,"method":method,"params":params});
    if let Some(session) = session {
        request["sessionId"] = json!(session);
    }
    ws.send(Message::Text(request.to_string().into()))
        .map_err(err)?;
    loop {
        if let Message::Text(text) = ws.read().map_err(err)? {
            let response: Value = serde_json::from_str(&text).map_err(err)?;
            if response["id"] == id {
                if let Some(error) = response.get("error") {
                    return Err(format!("recording CDP: {error}"));
                }
                return Ok(response["result"].clone());
            }
        }
    }
}

impl Recording {
    pub fn start(address: &str, opts: &Value, runtime: &Path) -> Result<Self> {
        let path = PathBuf::from(field(opts, "path")?);
        if !path.is_absolute() || path.exists() {
            return Err("recording requires a new absolute output path".into());
        }
        let fps = opts["fps"].as_u64().unwrap_or(30);
        if !(1..=60).contains(&fps) {
            return Err("recording fps must be 1..60".into());
        }
        let ffmpeg = field(opts, "ffmpeg")?;
        let width = opts["width"].as_u64().ok_or("recording width required")?;
        let height = opts["height"].as_u64().ok_or("recording height required")?;
        if !(2..=4096).contains(&width)
            || !(2..=2160).contains(&height)
            || width % 2 != 0
            || height % 2 != 0
        {
            return Err("recording viewport must have bounded even dimensions".into());
        }
        let (mut ws, _) = connect(address).map_err(err)?;
        if let MaybeTlsStream::Plain(socket) = ws.get_mut() {
            socket
                .set_read_timeout(Some(Duration::from_secs(10)))
                .map_err(err)?;
            socket
                .set_write_timeout(Some(Duration::from_secs(5)))
                .map_err(err)?;
        }
        let target = field(opts, "targetId")?;
        let attached = call(
            &mut ws,
            1,
            "Target.attachToTarget",
            json!({"targetId":target,"flatten":true}),
            None,
        )?;
        let session = field(&attached, "sessionId")?.to_owned();
        call(&mut ws, 2, "Page.enable", json!({}), Some(&session))?;
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).map_err(err)?;
        }
        let pending = path.with_extension("pending.mp4");
        if pending.exists() {
            return Err("recording pending output already exists".into());
        }
        let log_path = runtime.join("recording.log");
        let log = log_file(runtime, "recording.log")?;
        let mut command = Command::new(ffmpeg);
        command
            .args([
                "-hide_banner",
                "-loglevel",
                "error",
                "-nostdin",
                "-n",
                "-f",
                "image2pipe",
                "-vcodec",
                "mjpeg",
                "-framerate",
                &fps.to_string(),
                "-i",
                "pipe:0",
                "-an",
                "-vf",
                &format!("scale={width}:{height}:force_original_aspect_ratio=decrease:flags=lanczos,pad={width}:{height}:(ow-iw)/2:(oh-ih)/2,setsar=1"),
                "-c:v",
                "libx264",
                "-preset",
                "veryfast",
                "-crf",
                "18",
                "-pix_fmt",
                "yuv420p",
                "-movflags",
                "+faststart",
            ])
            .arg(&pending)
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(log);
        unsafe {
            command.pre_exec(|| {
                if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut child = command.spawn().map_err(err)?;
        let mut pipe = child.stdin.take().ok_or("encoder stdin unavailable")?;
        // On any setup error below, the encoder has to be reaped too.
        if let Err(error) = ws.send(Message::Text(
            json!({"id":3,"method":"Page.startScreencast",
                "params":{"format":"jpeg","quality":90,"everyNthFrame":1},"sessionId":session})
            .to_string()
            .into(),
        )) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(err(error));
        }
        if let MaybeTlsStream::Plain(socket) = ws.get_mut() {
            socket
                .set_read_timeout(Some(Duration::from_millis(30)))
                .map_err(err)?;
        }
        let stop = Arc::new(AtomicBool::new(false));
        let frames = Arc::new(AtomicU64::new(0));
        let latest = Arc::new(Mutex::new(Vec::<u8>::new()));
        let (ready_tx, ready_rx) = mpsc::sync_channel(1);
        let reader_stop = stop.clone();
        let reader_frames = frames.clone();
        let reader_latest = latest.clone();
        let mut timeline = File::create(path.with_extension("frames.jsonl")).map_err(err)?;
        let started = Instant::now();
        let reader = thread::spawn(move || {
            let result = (|| {
                let mut seq = 10;
                while !reader_stop.load(Ordering::Relaxed) {
                    let message = match ws.read() {
                        Ok(message) => message,
                        Err(tungstenite::Error::Io(e))
                            if matches!(
                                e.kind(),
                                io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                            ) =>
                        {
                            continue
                        }
                        Err(error) => return Err(err(error)),
                    };
                    if let Message::Text(text) = message {
                        let event: Value = serde_json::from_str(&text).map_err(err)?;
                        if event.get("error").is_some() {
                            return Err("screencast CDP operation failed".into());
                        }
                        if event["method"] == "Page.screencastFrame" {
                            let data = STANDARD
                                .decode(field(&event["params"], "data")?)
                                .map_err(err)?;
                            if data.len() > MAX_FRAME {
                                return Err("screencast frame exceeds bound".into());
                            }
                            *reader_latest.lock().map_err(err)? = data;
                            let count = reader_frames.fetch_add(1, Ordering::Relaxed) + 1;
                            writeln!(
                                timeline,
                                "{}",
                                json!({"frame":count,"at":started.elapsed().as_secs_f64(),
                                "metadata":event["params"]["metadata"]})
                            )
                            .map_err(err)?;
                            seq += 1;
                            ws.send(Message::Text(json!({"id":seq,"method":"Page.screencastFrameAck",
                                "sessionId":session,"params":{"sessionId":event["params"]["sessionId"]}}).to_string().into())).map_err(err)?;
                            if count == 1 {
                                let _ = ready_tx.send(());
                            }
                        }
                    }
                }
                // Connection ownership ends with this recorder, not the page.
                let _ = ws.send(Message::Text(
                    json!({"id":999999,"method":"Page.stopScreencast",
                    "sessionId":session,"params":{}})
                    .to_string()
                    .into(),
                ));
                let _ = ws.close(None);
                Ok(())
            })();
            reader_stop.store(true, Ordering::Relaxed);
            result
        });
        let encoder_stop = stop.clone();
        let encoder = thread::spawn(move || {
            let result = (|| {
                let mut encoded = 0;
                while !encoder_stop.load(Ordering::Relaxed) {
                    let image = latest.lock().map_err(err)?.clone();
                    if !image.is_empty() {
                        pipe.write_all(&image).map_err(err)?;
                        encoded += 1;
                    }
                    // Wall-clock pacing preserves waits and actual input motion.
                    let deadline =
                        started + Duration::from_secs_f64((encoded + 1) as f64 / fps as f64);
                    thread::sleep(
                        deadline
                            .saturating_duration_since(Instant::now())
                            .min(Duration::from_millis(50)),
                    );
                }
                Ok(encoded)
            })();
            encoder_stop.store(true, Ordering::Relaxed);
            drop(pipe);
            if result.is_err() {
                let _ = child.kill();
            }
            let status = child.wait().map_err(err)?;
            if !status.success() {
                return Err(format!(
                    "native frame encoder failed: {}",
                    fs::read_to_string(log_path).unwrap_or_default()
                ));
            }
            result
        });
        let recording = Self {
            stop,
            frames,
            started,
            path,
            reader: Some(reader),
            encoder: Some(encoder),
        };
        if ready_rx.recv_timeout(Duration::from_secs(10)).is_err() {
            let _ = recording.stop();
            return Err("native screencast produced no frame".into());
        }
        Ok(recording)
    }

    pub fn info(&self) -> Value {
        json!({"path":self.path,"at":self.started.elapsed().as_secs_f64(),
               "sourceFrames":self.frames.load(Ordering::Relaxed),"kind":"native-screencast"})
    }

    pub fn stop(mut self) -> Result<Value> {
        self.finish()
    }

    fn finish(&mut self) -> Result<Value> {
        self.stop.store(true, Ordering::Relaxed);
        let reader = self.reader.take().map(|h| {
            h.join()
                .map_err(|_| "frame reader panicked".to_string())
                .and_then(|r| r)
        });
        let encoder = self.encoder.take().map(|h| {
            h.join()
                .map_err(|_| "frame encoder panicked".to_string())
                .and_then(|r| r)
        });
        if let Some(result) = reader {
            result?;
        }
        if let Some(result) = encoder {
            let encoded = result?;
            if encoded == 0 {
                return Err("empty native recording".into());
            }
            fs::rename(self.path.with_extension("pending.mp4"), &self.path).map_err(err)?;
            let mut info = self.info();
            info["encodedFrames"] = json!(encoded);
            fs::write(
                self.path.with_extension("recording.json"),
                serde_json::to_vec_pretty(&info).map_err(err)?,
            )
            .map_err(err)?;
            return Ok(info);
        }
        Ok(self.info())
    }
}

impl Drop for Recording {
    fn drop(&mut self) {
        let _ = self.finish();
    }
}
