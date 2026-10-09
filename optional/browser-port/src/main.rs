//! An external port, not a NIF. Protocol stdout is exclusively packet-4 JSON.
//! Linux display support is explicit; a browser never runs with --no-sandbox.
use fs2::FileExt;
use serde_json::{json, Value};
#[cfg(feature = "x11")]
use std::io::{BufRead, BufReader};
use std::{
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    net::TcpStream,
    os::unix::{fs::PermissionsExt, process::CommandExt},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    thread,
    time::{Duration, Instant},
};
use tungstenite::{connect, stream::MaybeTlsStream, Message, WebSocket};
type Result<T> = std::result::Result<T, String>;
const MAX_FRAME: usize = 8 * 1024 * 1024;
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}
fn field<'a>(v: &'a Value, name: &str) -> Result<&'a str> {
    v[name]
        .as_str()
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing {name}"))
}
fn private_dir(path: &Path) -> Result<()> {
    if !path.is_absolute() {
        return Err("paths must be absolute".into());
    }
    fs::create_dir_all(path).map_err(err)?;
    if fs::symlink_metadata(path)
        .map_err(err)?
        .file_type()
        .is_symlink()
    {
        return Err("directory must not be a symlink".into());
    }
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(err)
}
fn log_file(root: &Path, name: &str) -> Result<File> {
    use std::os::unix::fs::OpenOptionsExt;
    OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(root.join(name))
        .map_err(err)
}
// Xauthority uses length-prefixed big-endian fields. FamilyWild is valid for
// local clients; the server reads the cookie before selecting its display.
#[cfg(feature = "x11")]
fn authority(path: &Path, display: &str, cookie: &[u8]) -> Result<()> {
    let mut bytes = Vec::new();
    bytes.extend_from_slice(&65535u16.to_be_bytes());
    for field in [&[][..], display.as_bytes(), b"MIT-MAGIC-COOKIE-1", cookie] {
        bytes.extend_from_slice(&(field.len() as u16).to_be_bytes());
        bytes.extend_from_slice(field);
    }
    use std::os::unix::fs::OpenOptionsExt;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(path)
        .map_err(err)?;
    file.write_all(&bytes).map_err(err)
}
fn spawn(
    exe: &str,
    args: &[String],
    display: Option<&str>,
    root: &Path,
    name: &str,
) -> Result<Child> {
    let log = log_file(root, name)?;
    let mut cmd = Command::new(exe);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(log.try_clone().map_err(err)?)
        .stderr(log)
        .process_group(0);
    if let Some(d) = display {
        if d.starts_with("wayland-") {
            cmd.env("WAYLAND_DISPLAY", d)
                .env("XDG_RUNTIME_DIR", root)
                .env("XDG_SESSION_TYPE", "wayland")
                .env_remove("DISPLAY")
                .env_remove("XAUTHORITY")
                .env_remove("SWAYSOCK")
                .env("WLR_BACKENDS", "headless")
                .env("WLR_LIBINPUT_NO_DEVICES", "1")
                .env("WLR_RENDERER", "pixman");
        } else {
            cmd.env("DISPLAY", d)
                .env("XDG_SESSION_TYPE", "x11")
                .env_remove("WAYLAND_DISPLAY")
                .env_remove("NIXOS_OZONE_WL")
                .env("XAUTHORITY", root.join("client.auth"));
        }
    }
    // Helpers die if this port is killed, including SIGKILL. Process groups are
    // also reaped on normal EOF; no detached browser or display survives.
    unsafe {
        cmd.pre_exec(|| {
            if libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM) == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    cmd.spawn().map_err(|e| format!("cannot start {name}: {e}"))
}
struct Session {
    children: Vec<Child>,
    profile: PathBuf,
    runtime: PathBuf,
    _lease: File,
    ws: Option<WebSocket<MaybeTlsStream<TcpStream>>>,
    seq: u64,
    info: Value,
}
impl Session {
    fn cdp(&mut self, method: &str, params: Value, session_id: Option<&str>) -> Result<Value> {
        self.seq += 1;
        let id = self.seq;
        let mut req = json!({"id":id,"method":method,"params":params});
        if let Some(s) = session_id {
            req["sessionId"] = json!(s);
        }
        let ws = self.ws.as_mut().ok_or("browser connection unavailable")?;
        ws.send(Message::Text(req.to_string().into()))
            .map_err(err)?;
        loop {
            let msg = ws.read().map_err(err)?;
            if let Message::Text(text) = msg {
                let response: Value = serde_json::from_str(&text).map_err(err)?;
                if response["id"] == id {
                    if response.get("error").is_some() {
                        return Err("browser rejected CDP operation".into());
                    }
                    return Ok(response["result"].clone());
                }
            }
        }
    }
    fn stop(&mut self) -> Result<Value> {
        // Browser.close flushes the actual profile (cookies, preferences, tabs).
        let requested = self.cdp("Browser.close", json!({}), None).is_ok();
        self.ws = None;
        let deadline = Instant::now() + Duration::from_secs(15);
        let mut clean = false;
        if let Some(browser) = self.children.last_mut() {
            while Instant::now() < deadline {
                if let Some(status) = browser.try_wait().map_err(err)? {
                    clean = requested && status.success();
                    break;
                }
                thread::sleep(Duration::from_millis(50));
            }
        }
        self.reap();
        if !clean {
            return Err("browser did not close cleanly; profile retained for recovery, save not acknowledged".into());
        }
        let marker = self.profile.join(".bl-saved");
        fs::write(
            &marker,
            format!(
                "{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap()
                    .as_millis()
            ),
        )
        .map_err(err)?;
        Ok(json!({"saved":true}))
    }
    fn reap(&mut self) {
        for c in self.children.iter_mut().rev() {
            if c.try_wait().ok().flatten().is_none() {
                unsafe {
                    libc::kill(-(c.id() as i32), libc::SIGTERM);
                }
            }
        }
        let end = Instant::now() + Duration::from_secs(2);
        while Instant::now() < end
            && self
                .children
                .iter_mut()
                .any(|c| c.try_wait().ok().flatten().is_none())
        {
            thread::sleep(Duration::from_millis(25));
        }
        for c in self.children.iter_mut().rev() {
            // Chromium descendants may outlive their leader. Always kill the
            // group after the grace period, then reap the direct child.
            unsafe {
                libc::kill(-(c.id() as i32), libc::SIGKILL);
            }
            let _ = c.wait();
        }
        self.children.clear();
        let _ = fs::remove_file(self.runtime.join("vnc.sock"));
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.reap();
    }
}
#[cfg(feature = "x11")]
fn start_x11(
    v: &Value,
    runtime: &Path,
    socket: &Path,
    width: u64,
    height: u64,
    s: &mut Session,
) -> Result<String> {
    // Xvfb selects and locks a free display itself, avoiding display-number races.
    let mut cookie = [0u8; 16];
    getrandom::fill(&mut cookie).map_err(err)?;
    authority(&runtime.join("server.auth"), "", &cookie)?;
    let display_file = runtime.join("display");
    let _ = fs::remove_file(&display_file);
    let mut cmd = Command::new(field(v, "xvfb")?);
    cmd.args([
        "-displayfd",
        "1",
        "-screen",
        "0",
        &format!("{width}x{height}x24"),
        "-nolisten",
        "tcp",
        "-auth",
        runtime
            .join("server.auth")
            .to_str()
            .ok_or("invalid runtime path")?,
    ])
    .stdin(Stdio::null())
    .stdout(Stdio::piped())
    .stderr(log_file(runtime, "display.log")?)
    .process_group(0);
    unsafe {
        cmd.pre_exec(|| {
            libc::prctl(libc::PR_SET_PDEATHSIG, libc::SIGTERM);
            Ok(())
        });
    }
    let mut x = cmd.spawn().map_err(|e| format!("cannot start Xvfb: {e}"))?;
    let out = x.stdout.take().unwrap();
    s.children.push(x);
    // Bound startup even if an executable doesn't implement -displayfd.
    let (tx, rx) = std::sync::mpsc::channel();
    thread::spawn(move || {
        let mut line = String::new();
        let _ = BufReader::new(out).read_line(&mut line);
        let _ = tx.send(line);
    });
    let number = rx
        .recv_timeout(Duration::from_secs(10))
        .map_err(|_| "display startup timed out")?;
    let n: u32 = number
        .trim()
        .parse()
        .map_err(|_| "display failed to start")?;
    authority(&runtime.join("client.auth"), &n.to_string(), &cookie)?;
    let display = format!(":{n}");
    s.children.push(spawn(
        field(v, "vnc")?,
        &[
            "-display".into(),
            display.clone(),
            "-unixsock".into(),
            socket.to_string_lossy().into_owned(),
            "-rfbport".into(),
            "0".into(),
            "-nopw".into(),
            "-forever".into(),
            "-shared".into(),
            "-quiet".into(),
            "-xkb".into(),
        ],
        Some(&display),
        runtime,
        "vnc.log",
    )?);
    Ok(display)
}

fn start_wayland(
    v: &Value,
    runtime: &Path,
    socket: &Path,
    width: u64,
    height: u64,
    s: &mut Session,
) -> Result<String> {
    // Never attach to or modify the user's compositor. All sockets are private.
    let config = runtime.join("sway.conf");
    fs::write(&config, format!("xwayland disable\noutput HEADLESS-1 mode {width}x{height}\nseat seat0 fallback true\ndefault_border none\ndefault_floating_border none\n" )).map_err(err)?;
    s.children.push(spawn(
        field(v, "compositor")?,
        &["--config".into(), config.to_string_lossy().into_owned()],
        Some("wayland-private"),
        runtime,
        "display.log",
    )?);
    let deadline = Instant::now() + Duration::from_secs(10);
    let display = loop {
        if s.children[0].try_wait().map_err(err)?.is_some() {
            return Err("Wayland compositor exited; inspect private runtime logs".into());
        }
        let found = fs::read_dir(runtime)
            .map_err(err)?
            .filter_map(|e| e.ok())
            .find(|e| {
                use std::os::unix::fs::FileTypeExt;
                e.file_name().to_string_lossy().starts_with("wayland-")
                    && e.file_type().map(|t| t.is_socket()).unwrap_or(false)
            });
        if let Some(e) = found {
            break e.file_name().to_string_lossy().into_owned();
        }
        if Instant::now() > deadline {
            return Err("Wayland compositor startup timed out".into());
        }
        thread::sleep(Duration::from_millis(25));
    };
    // Explicit config avoids inheriting a user's VNC authentication/listener policy.
    let vnc_config = runtime.join("wayvnc.conf");
    fs::write(&vnc_config, "enable_auth=false\n").map_err(err)?;
    s.children.push(spawn(
        field(v, "vnc")?,
        &[
            "--config".into(),
            vnc_config.to_string_lossy().into_owned(),
            "--unix-socket".into(),
            "--max-fps=30".into(),
            socket.to_string_lossy().into_owned(),
        ],
        Some(&display),
        runtime,
        "vnc.log",
    )?);
    Ok(display)
}

fn launch(v: &Value) -> Result<Session> {
    if std::env::var("BL_BROWSER_ENABLED").as_deref() == Ok("0") {
        return Err("native browser is disabled (BL_BROWSER_ENABLED=0)".into());
    }
    let backend = v["displayBackend"].as_str().unwrap_or("wayland");
    if !["wayland", "x11"].contains(&backend) {
        return Err("choose wayland or x11 displayBackend".into());
    }
    if backend == "x11" && !cfg!(feature = "x11") {
        return Err("X11 support was not built; explicitly enable the x11 feature".into());
    }

    let profile = PathBuf::from(field(v, "profile")?);
    let runtime = PathBuf::from(field(v, "runtime")?);
    private_dir(&profile)?;
    private_dir(&runtime)?;
    let lease = OpenOptions::new()
        .create(true)
        .truncate(false)
        .read(true)
        .write(true)
        .open(profile.join(".bl-owner"))
        .map_err(err)?;
    lease
        .try_lock_exclusive()
        .map_err(|_| "profile already has a writer".to_string())?;
    fs::write(profile.join(".bl-profile"), "native-browser-profile-v1").map_err(err)?;
    // A new owner after a crash must not accept the prior acknowledged save.
    let _ = fs::remove_file(profile.join(".bl-saved"));
    let mut s = Session {
        children: vec![],
        profile: profile.clone(),
        runtime: runtime.clone(),
        _lease: lease,
        ws: None,
        seq: 0,
        info: Value::Null,
    };
    let (width, height) = (
        v["width"].as_u64().unwrap_or(1280),
        v["height"].as_u64().unwrap_or(900),
    );
    if !(640..=4096).contains(&width) || !(480..=2160).contains(&height) {
        return Err("invalid display dimensions".into());
    }
    let socket = runtime.join("vnc.sock");
    if socket.as_os_str().len() > 100 {
        return Err("runtime path too long for Unix socket".into());
    }
    let _ = fs::remove_file(&socket);
    let display = match backend {
        "wayland" => start_wayland(v, &runtime, &socket, width, height, &mut s)?,
        "x11" => {
            #[cfg(feature = "x11")]
            {
                start_x11(v, &runtime, &socket, width, height, &mut s)?
            }
            #[cfg(not(feature = "x11"))]
            {
                return Err("X11 support was not built; explicitly enable the x11 feature".into());
            }
        }
        _ => unreachable!(),
    };
    let mut args = vec![
        format!("--user-data-dir={}", profile.display()),
        "--remote-debugging-port=0".into(),
        "--remote-debugging-address=127.0.0.1".into(),
        format!("--ozone-platform={backend}"),
        "--no-first-run".into(),
        "--no-default-browser-check".into(),
        "--restore-last-session".into(),
        format!("--window-size={width},{height}"),
        "--disable-dev-shm-usage".into(),
    ];
    if let Some(url) = v["url"].as_str() {
        if !url.starts_with("https://") && !url.starts_with("http://") {
            return Err("start URL must be HTTP(S)".into());
        }
        args.push(url.into());
    }
    let _ = fs::remove_file(profile.join("DevToolsActivePort"));
    s.children.push(spawn(
        field(v, "chromium")?,
        &args,
        Some(&display),
        &runtime,
        "browser.log",
    )?);
    let deadline = Instant::now() + Duration::from_secs(30);
    loop {
        for (i, c) in s.children.iter_mut().enumerate() {
            if let Some(status) = c.try_wait().map_err(err)? {
                return Err(format!("native child {i} exited during startup ({status}); inspect private runtime logs"));
            }
        }
        if let Ok(content) = fs::read_to_string(profile.join("DevToolsActivePort")) {
            let mut lines = content.lines();
            if let (Some(port), Some(path)) = (lines.next(), lines.next()) {
                if socket.exists() {
                    let address = format!("ws://127.0.0.1:{port}{path}");
                    if let Ok((mut ws, _)) = connect(&address) {
                        if let MaybeTlsStream::Plain(stream) = ws.get_mut() {
                            stream
                                .set_read_timeout(Some(Duration::from_secs(30)))
                                .map_err(err)?;
                            stream
                                .set_write_timeout(Some(Duration::from_secs(5)))
                                .map_err(err)?;
                        }
                        s.ws = Some(ws);
                        s.info = json!({"pid":s.children.last().unwrap().id(),"cdp":format!("http://127.0.0.1:{port}"),"vncSocket":socket,"display":display,"displayBackend":backend,"profile":profile});
                        return Ok(s);
                    }
                }
            }
        }
        if Instant::now() > deadline {
            return Err("browser startup timed out; inspect private runtime logs".into());
        }
        thread::sleep(Duration::from_millis(100));
    }
}
fn read_frame(r: &mut impl Read) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0; 4];
    // Partial headers are malformed; clean EOF is allowed only before a header.
    if r.read(&mut header[..1])? == 0 {
        return Ok(None);
    }
    r.read_exact(&mut header[1..])?;
    let len = u32::from_be_bytes(header) as usize;
    if len == 0 || len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid frame length",
        ));
    }
    let mut body = vec![0; len];
    r.read_exact(&mut body)?;
    Ok(Some(body))
}
fn write_frame(w: &mut impl Write, value: &Value) -> io::Result<()> {
    let bytes = serde_json::to_vec(value)?;
    if bytes.len() > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "response too large",
        ));
    }
    w.write_all(&(bytes.len() as u32).to_be_bytes())?;
    w.write_all(&bytes)?;
    w.flush()
}
fn main() {
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    let mut session: Option<Session> = None;
    loop {
        let frame = match read_frame(&mut input) {
            Ok(Some(f)) => f,
            Ok(None) => break,
            Err(_) => break,
        };
        let value: Value = match serde_json::from_slice(&frame) {
            Ok(v) => v,
            Err(_) => {
                let _ = write_frame(&mut output, &json!({"ok":false,"error":"invalid JSON"}));
                continue;
            }
        };
        let result: Result<Value> = (|| match field(&value, "op")? {
            "ping" => Ok(
                json!({"protocol":1,"backend":"native","platform":"linux","displayBackends":if cfg!(feature="x11") {vec!["wayland","x11"]} else {vec!["wayland"]}}),
            ),
            "launch" => {
                if session.is_some() {
                    return Err("already launched".into());
                }
                let s = launch(&value)?;
                let info = s.info.clone();
                session = Some(s);
                Ok(info)
            }
            "info" => {
                let s = session.as_mut().ok_or("not launched")?;
                for c in &mut s.children {
                    if c.try_wait().map_err(err)?.is_some() {
                        return Err("browser/display stopped".into());
                    }
                }
                Ok(s.info.clone())
            }
            "cdp" => session.as_mut().ok_or("not launched")?.cdp(
                field(&value, "method")?,
                value["params"]
                    .as_object()
                    .map(|_| value["params"].clone())
                    .unwrap_or(json!({})),
                value["sessionId"].as_str(),
            ),
            "forget" => {
                let profile = PathBuf::from(field(&value, "profile")?);
                if !profile.is_absolute()
                    || profile.parent().is_none()
                    || profile.file_name().is_none()
                {
                    return Err("invalid profile path".into());
                }
                if profile.exists() {
                    if fs::symlink_metadata(&profile)
                        .map_err(err)?
                        .file_type()
                        .is_symlink()
                    {
                        return Err("profile must not be a symlink".into());
                    }
                    if fs::read_to_string(profile.join(".bl-profile"))
                        .map_err(|_| "not a managed browser profile")?
                        != "native-browser-profile-v1"
                    {
                        return Err("not a managed browser profile".into());
                    }
                    let lease = OpenOptions::new()
                        .read(true)
                        .write(true)
                        .create(true)
                        .truncate(false)
                        .open(profile.join(".bl-owner"))
                        .map_err(err)?;
                    lease
                        .try_lock_exclusive()
                        .map_err(|_| "profile already has a writer".to_string())?;
                    fs::remove_dir_all(&profile).map_err(err)?;
                }
                Ok(json!({"forgotten":true}))
            }
            "stop" => {
                let result = session.as_mut().ok_or("not launched")?.stop();
                session = None;
                result
            }
            _ => Err("unknown operation".into()),
        })();
        let response = match result {
            Ok(v) => json!({"id":value["id"],"ok":true,"result":v}),
            Err(e) => json!({"id":value["id"],"ok":false,"error":e}),
        };
        if write_frame(&mut output, &response).is_err() {
            break;
        }
    }
    if let Some(mut s) = session {
        let _ = s.stop();
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[cfg(not(feature = "x11"))]
    #[test]
    fn x11_is_rejected_without_the_explicit_feature() {
        // No paths are supplied: rejection must precede filesystem/process IO.
        assert!(launch(&json!({"displayBackend":"x11"}))
            .err()
            .unwrap()
            .contains("X11 support was not built"));
    }
    #[test]
    fn framing_roundtrip() {
        let v = json!({"hello":"é\n世界"});
        let mut bytes = Vec::new();
        write_frame(&mut bytes, &v).unwrap();
        let body = read_frame(&mut bytes.as_slice()).unwrap().unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&body).unwrap(), v);
    }
    #[test]
    fn malformed_frames() {
        for b in [
            vec![0],
            vec![0, 0, 0, 0],
            vec![255, 255, 255, 255],
            vec![0, 0, 0, 2, 1],
        ] {
            assert!(read_frame(&mut b.as_slice()).is_err());
        }
    }
    #[test]
    fn clean_eof() {
        assert!(read_frame(&mut [].as_slice()).unwrap().is_none());
    }
}
