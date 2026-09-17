// Daemon fast-path for the `bl` launcher.
//
// When a warm `bl daemon` is running for the caller's tree, the launcher
// forwards the command over an `AF_UNIX` socket and streams the reply, instead
// of cold-booting the release VM (~1.2s → ~30ms). This module is a MINIMAL,
// self-contained ETF (Erlang term) codec + socket client — no serde, no extra
// crates, matching the launcher's "std + flate2 + tar + sha2 only" rule.
//
// It speaks exactly the subset of `BeamLisp.Daemon.Protocol` the client needs:
// encode hello / request / stdin_reply, decode ready / reject / stdout /
// stderr / stdin / exit / heartbeat. Frames are length-prefixed (`{packet,4}`,
// 4-byte big-endian) ETF payloads.
//
// Everything here is best-effort: any error resolving/connecting/handshaking
// returns `None`/`Err` so the launcher falls back to the cold path. The ONLY
// irreversible point is AFTER a request frame is sent — from there a lost
// connection is "unknown outcome" (exit 1), never a silent standalone retry.

#[cfg(unix)]
use std::io::{Read, Write};
#[cfg(unix)]
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

// ── ETF tags (subset) ───────────────────────────────────────────────────────
const ETF_VERSION: u8 = 131;
const SMALL_INT: u8 = 97; // u8
const INTEGER: u8 = 98; // i32 big-endian
const SMALL_BIG: u8 = 110; // bignum (we only decode small)
const ATOM_UTF8: u8 = 118; // len:u16 + bytes
const SMALL_ATOM_UTF8: u8 = 119; // len:u8 + bytes
const SMALL_TUPLE: u8 = 104; // arity:u8 + elems
const LARGE_TUPLE: u8 = 105; // arity:u32 + elems
const NIL: u8 = 106; // []
const STRING: u8 = 107; // len:u16 + bytes (list of small ints)
const LIST: u8 = 108; // len:u32 + elems + tail
const BINARY: u8 = 109; // len:u32 + bytes
const MAP: u8 = 116; // pairs:u32 + (k,v)...

// ── a decoded term (only what we consume) ───────────────────────────────────
#[derive(Debug, Clone)]
pub enum Term {
    Int(i64),
    Atom(String),
    Binary(Vec<u8>),
    Tuple(Vec<Term>),
    List(Vec<Term>),
    Map(Vec<(Term, Term)>),
    Other,
}

impl Term {
    fn as_atom(&self) -> Option<&str> {
        if let Term::Atom(s) = self {
            Some(s)
        } else {
            None
        }
    }
    fn as_int(&self) -> Option<i64> {
        if let Term::Int(i) = self {
            Some(*i)
        } else {
            None
        }
    }
    fn as_bytes(&self) -> Option<&[u8]> {
        match self {
            Term::Binary(b) => Some(b),
            _ => None,
        }
    }
}

// ── encoder ─────────────────────────────────────────────────────────────────

pub struct Enc {
    buf: Vec<u8>,
}

impl Enc {
    fn new() -> Self {
        let mut buf = Vec::with_capacity(256);
        buf.push(ETF_VERSION);
        Enc { buf }
    }

    fn atom(&mut self, a: &str) {
        let bytes = a.as_bytes();
        if bytes.len() < 256 {
            self.buf.push(SMALL_ATOM_UTF8);
            self.buf.push(bytes.len() as u8);
        } else {
            self.buf.push(ATOM_UTF8);
            self.buf.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
        }
        self.buf.extend_from_slice(bytes);
    }

    fn small_int(&mut self, n: u8) {
        self.buf.push(SMALL_INT);
        self.buf.push(n);
    }

    fn binary(&mut self, b: &[u8]) {
        self.buf.push(BINARY);
        self.buf.extend_from_slice(&(b.len() as u32).to_be_bytes());
        self.buf.extend_from_slice(b);
    }

    fn tuple_header(&mut self, arity: usize) {
        if arity < 256 {
            self.buf.push(SMALL_TUPLE);
            self.buf.push(arity as u8);
        } else {
            self.buf.push(LARGE_TUPLE);
            self.buf.extend_from_slice(&(arity as u32).to_be_bytes());
        }
    }

    fn map_header(&mut self, pairs: usize) {
        self.buf.push(MAP);
        self.buf.extend_from_slice(&(pairs as u32).to_be_bytes());
    }

    // a proper list of binaries → ETF LIST with NIL tail
    fn list_of_binaries(&mut self, items: &[Vec<u8>]) {
        if items.is_empty() {
            self.buf.push(NIL);
            return;
        }
        self.buf.push(LIST);
        self.buf.extend_from_slice(&(items.len() as u32).to_be_bytes());
        for it in items {
            self.binary(it);
        }
        self.buf.push(NIL);
    }

    fn finish(self) -> Vec<u8> {
        self.buf
    }
}

// ── decoder ─────────────────────────────────────────────────────────────────

struct Dec<'a> {
    b: &'a [u8],
    i: usize,
}

impl<'a> Dec<'a> {
    fn new(b: &'a [u8]) -> Option<Self> {
        if b.first().copied()? != ETF_VERSION {
            return None;
        }
        Some(Dec { b, i: 1 })
    }

    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.i)?;
        self.i += 1;
        Some(v)
    }
    fn u16(&mut self) -> Option<u16> {
        let s = self.b.get(self.i..self.i + 2)?;
        self.i += 2;
        Some(u16::from_be_bytes([s[0], s[1]]))
    }
    fn u32(&mut self) -> Option<u32> {
        let s = self.b.get(self.i..self.i + 4)?;
        self.i += 4;
        Some(u32::from_be_bytes([s[0], s[1], s[2], s[3]]))
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let s = self.b.get(self.i..self.i + n)?;
        self.i += n;
        Some(s)
    }

    fn term(&mut self) -> Option<Term> {
        match self.u8()? {
            SMALL_INT => Some(Term::Int(self.u8()? as i64)),
            INTEGER => {
                let s = self.take(4)?;
                Some(Term::Int(i32::from_be_bytes([s[0], s[1], s[2], s[3]]) as i64))
            }
            SMALL_BIG => {
                let n = self.u8()? as usize;
                let sign = self.u8()?;
                let bytes = self.take(n)?;
                let mut v: i64 = 0;
                for (k, byte) in bytes.iter().enumerate().take(8) {
                    v |= (*byte as i64) << (8 * k);
                }
                Some(Term::Int(if sign == 0 { v } else { -v }))
            }
            ATOM_UTF8 => {
                let n = self.u16()? as usize;
                let s = self.take(n)?;
                Some(Term::Atom(String::from_utf8_lossy(s).into_owned()))
            }
            SMALL_ATOM_UTF8 => {
                let n = self.u8()? as usize;
                let s = self.take(n)?;
                Some(Term::Atom(String::from_utf8_lossy(s).into_owned()))
            }
            BINARY => {
                let n = self.u32()? as usize;
                let s = self.take(n)?;
                Some(Term::Binary(s.to_vec()))
            }
            STRING => {
                let n = self.u16()? as usize;
                let s = self.take(n)?;
                Some(Term::Binary(s.to_vec()))
            }
            NIL => Some(Term::List(vec![])),
            SMALL_TUPLE => {
                let arity = self.u8()? as usize;
                self.tuple(arity)
            }
            LARGE_TUPLE => {
                let arity = self.u32()? as usize;
                self.tuple(arity)
            }
            LIST => {
                let n = self.u32()? as usize;
                let mut items = Vec::with_capacity(n);
                for _ in 0..n {
                    items.push(self.term()?);
                }
                let _tail = self.term()?; // NIL for a proper list
                Some(Term::List(items))
            }
            MAP => {
                let n = self.u32()? as usize;
                let mut pairs = Vec::with_capacity(n);
                for _ in 0..n {
                    let k = self.term()?;
                    let v = self.term()?;
                    pairs.push((k, v));
                }
                Some(Term::Map(pairs))
            }
            _ => Some(Term::Other),
        }
    }

    fn tuple(&mut self, arity: usize) -> Option<Term> {
        let mut elems = Vec::with_capacity(arity);
        for _ in 0..arity {
            elems.push(self.term()?);
        }
        Some(Term::Tuple(elems))
    }
}

pub fn decode(bytes: &[u8]) -> Option<Term> {
    Dec::new(bytes)?.term()
}

// ── tree identity (must match BeamLisp.Daemon.Paths) ─────────────────────────

/// The 16-hex tree id = first 16 hex of sha256(realpath(root)).
pub fn tree_id(root: &Path) -> String {
    let canonical = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    let full = sha256_hex(canonical.to_string_lossy().as_bytes());
    full[..16].to_string()
}

/// The 32-byte tree fingerprint = sha256(realpath(root)).
pub fn tree_fingerprint(root: &Path) -> Vec<u8> {
    let canonical = std::fs::canonicalize(root).unwrap_or_else(|_| root.to_path_buf());
    sha256_bytes(canonical.to_string_lossy().as_bytes())
}

/// The runtime dir the daemon binds under (mirror of Paths.runtime_dir).
fn runtime_dir() -> Option<PathBuf> {
    if let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") {
        if !dir.is_empty() {
            return Some(PathBuf::from(dir).join("beam_lisp"));
        }
    }
    // /tmp/beam_lisp-<uid>
    let uid = unsafe { libc_getuid() };
    Some(std::env::temp_dir().join(format!("beam_lisp-{uid}")))
}

// getuid without linking libc: read /proc/self/status? Simpler: use the
// numeric owner of a probe. But the daemon uses the real uid; the XDG path is
// the common case on this platform, so a best-effort tmp fallback suffices.
#[cfg(unix)]
extern "C" {
    #[link_name = "getuid"]
    fn c_getuid() -> u32;
}
#[cfg(unix)]
unsafe fn libc_getuid() -> u32 {
    c_getuid()
}
#[cfg(not(unix))]
unsafe fn libc_getuid() -> u32 {
    0
}

pub struct Endpoints {
    pub sock: PathBuf,
    pub token: PathBuf,
}

pub fn endpoints(root: &Path) -> Option<Endpoints> {
    let dir = runtime_dir()?;
    let id = tree_id(root);
    Some(Endpoints {
        sock: dir.join(format!("{id}.sock")),
        token: dir.join(format!("{id}.token")),
    })
}

/// Walk up from `cwd` to the nearest beam-lisp tree root (checkout or extracted
/// release), falling back to `cwd` itself when no checkout encloses it.
/// `BL_DAEMON_ROOT` overrides.
///
/// THE FALLBACK MATCHES THE DAEMON'S OWN RULE. `BeamLisp.Daemon.start/1` keys
/// its server on `BL_DAEMON_ROOT || File.cwd!()` — it does not search upward —
/// so a daemon started from a scratch directory is keyed on that directory,
/// while a launcher that resolved nothing there would never look for it: no
/// fast-path, no `daemon start` handoff, a cold VM per command forever. A
/// directory is a tree; a checkout found above it is a better answer to "which
/// tree", which is why the search still comes first.
pub fn resolve_root(cwd: &Path) -> Option<PathBuf> {
    if let Ok(r) = std::env::var("BL_DAEMON_ROOT") {
        if !r.is_empty() {
            return std::fs::canonicalize(&r).ok().or(Some(PathBuf::from(r)));
        }
    }
    let mut dir = cwd.to_path_buf();
    loop {
        if is_tree_root(&dir) {
            return std::fs::canonicalize(&dir).ok().or(Some(dir));
        }
        if !dir.pop() {
            return canonical_or(cwd.to_path_buf());
        }
    }
}

fn canonical_or(path: PathBuf) -> Option<PathBuf> {
    std::fs::canonicalize(&path).ok().or(Some(path))
}

fn is_tree_root(dir: &Path) -> bool {
    dir.join("priv/boot/core.bl").exists()
        || (dir.join("bin/bl").exists() && dir.join("releases").is_dir())
}

// ── the client: attach + stream ─────────────────────────────────────────────

#[derive(Debug)]
pub enum Attach {
    /// A terminal frame arrived; exit with this code.
    Exit(i32),
    /// The daemon is not reachable / not usable; fall back to cold exec.
    Fallback,
    /// The daemon refused a restart-required / drift; the caller should
    /// (optionally) restart the daemon then cold-exec.
    RestartRequired,
    /// The connection was lost AFTER the request was sent — unknown outcome.
    /// Never retry; exit non-zero.
    LostAfterSend,
    /// Nothing arrived for the read timeout, but the socket is still OPEN. The
    /// command is probably still running: silence is not loss.
    Stalled(u64),
}

#[cfg(unix)]
pub fn try_attach(root: &Path, argv: &[String]) -> Attach {
    let ep = match endpoints(root) {
        Some(e) => e,
        None => return Attach::Fallback,
    };
    if !ep.sock.exists() {
        return Attach::Fallback;
    }
    let token = match std::fs::read(&ep.token) {
        Ok(t) => t,
        Err(_) => return Attach::Fallback,
    };

    let mut stream = match UnixStream::connect(&ep.sock) {
        Ok(s) => s,
        Err(_) => return Attach::Fallback,
    };
    let _ = stream.set_read_timeout(Some(read_timeout()));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    // hello
    let fp = tree_fingerprint(root);
    let hello = encode_hello(&fp, &token);
    if send_frame(&mut stream, &hello).is_err() {
        return Attach::Fallback;
    }

    let hello_reply = match recv_frame(&mut stream) {
        Ok(b) => decode(&b),
        // a daemon that cannot answer hello within the timeout is unusable: cold.
        Err(_) => return Attach::Fallback,
    };
    match hello_reply {
        // PLAN-121/123: the daemon runs each request as its OWN VM process, so
        // it is never "busy" — a ready hello means attach and send.
        Some(Term::Tuple(t)) if is_ready(&t) => {}
        Some(Term::Tuple(t)) if is_reject(&t, "restart_required") => return Attach::RestartRequired,
        Some(Term::Tuple(_)) => return Attach::Fallback, // other reject (wrong tree/unauthorized)
        _ => return Attach::Fallback,
    }

    // request — from here, NEVER fall back (side effects may happen).
    let cwd = std::env::current_dir().unwrap_or_else(|_| root.to_path_buf());
    let env_paths = collect_env_paths();
    // THE CALLER'S ENVIRONMENT, on the wire. A daemon runs a request in its OWN
    // environment (D17: `FOO=bar bl eval '(System/get_env "FOO")'` answered nil
    // warm and bar cold), which is why serving had to be cut over to `bl serve`
    // and why the suites export BL_DAEMON=off. Carrying it here makes a warm run
    // and a cold run the same program, which is what lets those workarounds go
    // back to being performance choices.
    let req = encode_request(argv, &cwd, &env_paths, &collect_env());
    if send_frame(&mut stream, &req).is_err() {
        return Attach::LostAfterSend;
    }

    // Silence is not loss: the read deadline that follows (1800 s, or
    // BL_DAEMON_READ_TIMEOUT) is what turns a stalled wait into an HONEST
    // message — "the command is probably still running, and it is NOT re-run
    // here" — instead of the false "connection lost" that used to be printed
    // at 30 s and made a caller retry a command that had already run
    // (FUP-013). Measured under this deadline: `bl test` 210 s, `bl lsp check`
    // over the plant 9 m 37 s through a warm daemon, both completed.

    stream_until_exit(&mut stream)
}

#[cfg(not(unix))]
pub fn try_attach(_root: &Path, _argv: &[String]) -> Attach {
    Attach::Fallback
}

#[cfg(unix)]
fn stream_until_exit(stream: &mut UnixStream) -> Attach {
    // A served command that fails must SAY so. The daemon's own failure frames
    // are not the only way to reach a non-zero exit — a worker can die, a boot
    // can fail before the output proxy exists — and an exit with nothing on
    // either stream is indistinguishable from a hang that returned. This guard
    // is the difference between a diagnosis and a mystery: it fires only when
    // the daemon exited non-zero having written nothing at all.
    let mut wrote_anything = false;
    loop {
        let frame = match recv_frame(stream) {
            Ok(f) => f,
            // Silence is not loss. The socket is still open and the worker is
            // still running; only our patience ran out. Saying "connection lost"
            // here is a false diagnosis — measured: a 210s test crossed a 30s
            // timeout that had nothing to do with the connection.
            Err(FrameErr::Timeout) => return Attach::Stalled(read_timeout_secs()),
            Err(FrameErr::Lost) => return Attach::LostAfterSend,
        };
        let term = match decode(&frame) {
            Some(t) => t,
            None => continue,
        };
        if let Term::Tuple(t) = term {
            // {:bl, 1, tag, id, ...}
            let tag = t.get(2).and_then(|x| x.as_atom()).unwrap_or("");
            match tag {
                // {:bl, 1, :stdout, id, seq, bytes} — bytes is index 5
                "stdout" => {
                    if let Some(b) = t.get(5).and_then(|x| x.as_bytes()) {
                        let _ = std::io::stdout().write_all(b);
                        let _ = std::io::stdout().flush();
                        wrote_anything = wrote_anything || !b.is_empty();
                    }
                }
                "stderr" => {
                    if let Some(b) = t.get(5).and_then(|x| x.as_bytes()) {
                        let _ = std::io::stderr().write_all(b);
                        let _ = std::io::stderr().flush();
                        wrote_anything = wrote_anything || !b.is_empty();
                    }
                }
                // {:bl, 1, :heartbeat, id, ms} and {:bl, 1, :watch, id, seq,
                // payload} are liveness/streaming frames a one-shot command does
                // not act on — the read deadline is the real limit.
                // (handled by the catch-all below)
                // {:bl, 1, :stdin, id, seq, prompt} — seq is index 4
                "stdin" => {
                    // request one line from our stdin, reply
                    let seq = t.get(4).and_then(|x| x.as_int()).unwrap_or(0);
                    let mut line = String::new();
                    let n = std::io::stdin().read_line(&mut line).unwrap_or(0);
                    let reply = if n == 0 {
                        encode_stdin_eof(seq)
                    } else {
                        encode_stdin_reply(seq, line.as_bytes())
                    };
                    let _ = send_frame(stream, &reply);
                }
                // {:bl, 1, :exit, id, code} — code is index 4
                "exit" => {
                    let code = t.get(4).and_then(|x| x.as_int()).unwrap_or(0);
                    if code != 0 && !wrote_anything {
                        eprintln!(
                            "bl: the daemon ended this command with exit {code} and no output; \
                             run it cold (BL_DAEMON=off bl …) to see why"
                        );
                    }
                    return Attach::Exit(code as i32);
                }
                // {:bl, 1, :failed, id, code, msg} — code is index 4, msg is 5
                "failed" => {
                    let code = t.get(4).and_then(|x| x.as_int()).unwrap_or(1);
                    if let Some(b) = t.get(5).and_then(|x| x.as_bytes()) {
                        let _ = std::io::stderr().write_all(b);
                        let _ = std::io::stderr().flush();
                        wrote_anything = wrote_anything || !b.is_empty();
                    }
                    if !wrote_anything {
                        eprintln!("bl: the daemon refused this command (exit {code})");
                    }
                    return Attach::Exit(code as i32);
                }
                // heartbeat/watch/other liveness frames: a one-shot command has
                // nothing to do with them, and the read deadline is the real
                // limit on "still running".
                "heartbeat" | "watch" => {}
                _ => {}
            }
        }
    }
}

// ── frame io ({packet,4}) ────────────────────────────────────────────────────

#[cfg(unix)]
fn send_frame(stream: &mut UnixStream, payload: &[u8]) -> std::io::Result<()> {
    let len = (payload.len() as u32).to_be_bytes();
    stream.write_all(&len)?;
    stream.write_all(payload)?;
    stream.flush()
}

/// Why a frame read ended. The distinction is the point: a TIMEOUT means the
/// socket is healthy and the peer is quiet, a LOSS means it is gone.
#[cfg(unix)]
#[derive(Debug, PartialEq, Eq)]
enum FrameErr {
    Timeout,
    Lost,
}

/// How long the client waits for the NEXT frame before giving up. A command can
/// run for minutes without printing anything — the pool test takes 210s — and
/// the old hardcoded 30s turned that silence into "connection lost mid-command;
/// outcome unknown", a diagnosis that was simply false. Override with
/// `BL_DAEMON_READ_TIMEOUT` (seconds).
#[cfg(unix)]
fn read_timeout_secs() -> u64 {
    std::env::var("BL_DAEMON_READ_TIMEOUT")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|n| *n > 0)
        .unwrap_or(DEFAULT_READ_TIMEOUT_SECS)
}

#[cfg(unix)]
fn read_timeout() -> Duration {
    Duration::from_secs(read_timeout_secs())
}

/// Long enough for a real test suite to finish in silence, short enough that a
/// genuinely wedged daemon does not hold a terminal forever.
#[cfg(unix)]
const DEFAULT_READ_TIMEOUT_SECS: u64 = 1_800;

#[cfg(unix)]
fn recv_frame(stream: &mut UnixStream) -> Result<Vec<u8>, FrameErr> {
    let mut lenbuf = [0u8; 4];
    read_exact_classified(stream, &mut lenbuf)?;
    let n = u32::from_be_bytes(lenbuf) as usize;
    if n > 64 * 1024 * 1024 {
        return Err(FrameErr::Lost);
    }
    let mut buf = vec![0u8; n];
    read_exact_classified(stream, &mut buf)?;
    Ok(buf)
}

#[cfg(unix)]
fn read_exact_classified(stream: &mut UnixStream, buf: &mut [u8]) -> Result<(), FrameErr> {
    use std::io::ErrorKind;
    stream.read_exact(buf).map_err(|e| match e.kind() {
        ErrorKind::TimedOut | ErrorKind::WouldBlock => FrameErr::Timeout,
        _ => FrameErr::Lost,
    })
}

// ── frame builders ───────────────────────────────────────────────────────────

fn encode_hello(tree: &[u8], token: &[u8]) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(4);
    e.atom("bl");
    e.small_int(1);
    e.atom("hello");
    e.map_header(2);
    e.atom("tree");
    e.binary(tree);
    e.atom("token");
    e.binary(token);
    e.finish()
}

fn encode_request(argv: &[String], cwd: &Path, env_paths: &[String], env: &[(String, String)]) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(5);
    e.atom("bl");
    e.small_int(1);
    e.atom("request");
    // 16-byte request id
    let id = request_id();
    e.binary(&id);
    // map %{argv, cwd, env_paths, env, tty}
    e.map_header(5);
    e.atom("argv");
    e.list_of_binaries(&argv.iter().map(|a| a.as_bytes().to_vec()).collect::<Vec<_>>());
    e.atom("cwd");
    e.binary(cwd.to_string_lossy().as_bytes());
    e.atom("env_paths");
    e.list_of_binaries(&env_paths.iter().map(|p| p.as_bytes().to_vec()).collect::<Vec<_>>());
    e.atom("env");
    e.map_header(env.len());
    for (k, v) in env {
        e.binary(k.as_bytes());
        e.binary(v.as_bytes());
    }
    e.atom("tty");
    e.map_header(0);
    e.finish()
}

/// The environment to send: the caller's, bounded.
///
/// Bounded because the frame is one term and a hostile environment should not
/// be able to make the daemon allocate without limit; 1024 names and 64 KiB per
/// value is far above any real shell (a PATH with 200 entries is ~10 KiB).
fn collect_env() -> Vec<(String, String)> {
    const MAX_VARS: usize = 1024;
    const MAX_VALUE: usize = 64 * 1024;

    std::env::vars()
        .filter(|(_, v)| v.len() <= MAX_VALUE)
        .take(MAX_VARS)
        .collect()
}

fn encode_stdin_reply(seq: i64, data: &[u8]) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(5);
    e.atom("bl");
    e.small_int(1);
    e.atom("stdin_reply");
    // id is unused server-side for routing (seq is), send empty 16 bytes
    e.binary(&[0u8; 16]);
    e.int(seq);
    e.binary(data);
    e.finish()
}

fn encode_stdin_eof(seq: i64) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(5);
    e.atom("bl");
    e.small_int(1);
    e.atom("stdin_reply");
    e.binary(&[0u8; 16]);
    e.int(seq);
    e.atom("eof");
    e.finish()
}

impl Enc {
    fn int(&mut self, n: i64) {
        if (0..256).contains(&n) {
            self.small_int(n as u8);
        } else if (i32::MIN as i64..=i32::MAX as i64).contains(&n) {
            self.buf.push(INTEGER);
            self.buf.extend_from_slice(&(n as i32).to_be_bytes());
        } else {
            // small big
            self.buf.push(SMALL_BIG);
            let mag = n.unsigned_abs();
            let bytes = mag.to_le_bytes();
            let len = bytes.iter().rposition(|&b| b != 0).map(|p| p + 1).unwrap_or(1);
            self.buf.push(len as u8);
            self.buf.push(if n < 0 { 1 } else { 0 });
            self.buf.extend_from_slice(&bytes[..len]);
        }
    }
}

fn request_id() -> [u8; 16] {
    // Not security-sensitive (the token authenticates the connection); a
    // time+pid mix gives a unique 16-byte id per request.
    let mut id = [0u8; 16];
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    id.copy_from_slice(&nanos.to_le_bytes());
    let pid = std::process::id().to_le_bytes();
    id[12..16].copy_from_slice(&pid);
    id
}

fn collect_env_paths() -> Vec<String> {
    // mirror the CLI: BEAM_LISP_PATH is a colon list of extra roots
    match std::env::var("BEAM_LISP_PATH") {
        Ok(v) if !v.is_empty() => v.split(':').map(|s| s.to_string()).collect(),
        _ => vec![],
    }
}

// ── term shape helpers ───────────────────────────────────────────────────────

// ── the transport decision, shaped by the tree ───────────────────────────────

#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum DaemonMode {
    /// Never attach: a cold VM per command (`BL_DAEMON=off`).
    Off,
    /// Attach to the global daemon (the default). There is no "busy" — each
    /// request runs as its own VM process (PLAN-121), so there is no queue mode.
    Auto,
}

/// The effective mode: the CALLER's environment first, else the tree's own
/// declaration in `env.bl`.
///
/// The declaration half is new, and it was impossible before: the transport was
/// chosen HERE, before the project env is applied, so a tree declaring
/// `env.bl :env {"BL_DAEMON" "off"}` was still served by a warm daemon —
/// measured 2026-09-16, in a tree that declared exactly that and could not tell
/// why its runs kept the daemon's environment. A declaration is a DEFAULT, so a
/// value in the environment still wins.
pub fn daemon_mode(root: &Path) -> DaemonMode {
    let raw = std::env::var("BL_DAEMON")
        .ok()
        .filter(|v| !v.is_empty())
        .or_else(|| declared_daemon_mode(root));

    match raw.as_deref() {
        Some("off") => DaemonMode::Off,
        _ => DaemonMode::Auto,
    }
}

/// `"BL_DAEMON" "off"` out of the tree's `env.bl`, by SCAN.
///
/// A scan, not an evaluation: the launcher must never run the tree's code to
/// decide how to run its commands, and the value it wants is a literal in a data
/// map by construction (`env.bl` is read as data — its own header says so).
/// Only a value the transport understands is accepted, so a mention of the key
/// in prose cannot silently become policy.
fn declared_daemon_mode(root: &Path) -> Option<String> {
    let text = std::fs::read_to_string(root.join("env.bl")).ok()?;
    let key = "\"BL_DAEMON\"";
    let at = text.find(key)?;
    let rest = &text[at + key.len()..];
    let open = rest.find('"')?;
    let tail = &rest[open + 1..];
    let close = tail.find('"')?;
    let value = tail[..close].to_string();

    matches!(value.as_str(), "off" | "auto").then_some(value)
}

fn is_ready(t: &[Term]) -> bool {
    t.len() >= 3
        && t.first().and_then(|x| x.as_atom()) == Some("bl")
        && t.get(2).and_then(|x| x.as_atom()) == Some("ready")
}

fn is_reject(t: &[Term], reason: &str) -> bool {
    t.len() >= 4
        && t.first().and_then(|x| x.as_atom()) == Some("bl")
        && t.get(2).and_then(|x| x.as_atom()) == Some("reject")
        && t.get(3).and_then(|x| x.as_atom()) == Some(reason)
}

// ── tests: golden ETF vectors (authority = Elixir :erlang.term_to_binary) ────
#[cfg(test)]
mod tests {
    use super::*;

    fn unhex(s: &str) -> Vec<u8> {
        (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
    }

    // decode {:bl,1,:ready,%{...}}
    #[test]
    fn decodes_ready() {
        let bytes = unhex("8368047702626c610177057265616479740000000577037069646d00000003313233770c636f6d70696c65725f6b65796d00000003616263770f6461656d6f6e5f6275696c645f69646d00000001317709757074696d655f6d736105770b71756575655f64657074686100");
        let t = decode(&bytes).unwrap();
        if let Term::Tuple(v) = t {
            assert_eq!(v[0].as_atom(), Some("bl"));
            assert_eq!(v[2].as_atom(), Some("ready"));
            assert!(is_ready(&v));
        } else {
            panic!("not a tuple");
        }
    }

    // decode {:bl,1,:stdout,id,0,"hello\n"} — bytes at index 5
    #[test]
    fn decodes_stdout_at_index_5() {
        let bytes = unhex("8368067702626c610177067374646f75746d000000100707070707070707070707070707070761006d0000000668656c6c6f0a");
        if let Term::Tuple(v) = decode(&bytes).unwrap() {
            assert_eq!(v[2].as_atom(), Some("stdout"));
            assert_eq!(v[5].as_bytes(), Some(&b"hello\n"[..]));
        } else {
            panic!("not a tuple");
        }
    }

    // decode {:bl,1,:exit,id,42} — code at index 4
    #[test]
    fn decodes_exit_code_at_index_4() {
        let bytes = unhex("8368057702626c61017704657869746d0000001007070707070707070707070707070707612a");
        if let Term::Tuple(v) = decode(&bytes).unwrap() {
            assert_eq!(v[2].as_atom(), Some("exit"));
            assert_eq!(v[4].as_int(), Some(42));
        } else {
            panic!("not a tuple");
        }
    }

    // decode {:bl,1,:reject,:restart_required,"stale",%{}}
    #[test]
    fn decodes_reject_restart_required() {
        let bytes = unhex("8368067702626c6101770672656a6563747710726573746172745f72657175697265646d000000057374616c657400000000");
        if let Term::Tuple(v) = decode(&bytes).unwrap() {
            assert!(is_reject(&v, "restart_required"));
        } else {
            panic!("not a tuple");
        }
    }

    // our encoder's hello must decode back to the same shape
    #[test]
    fn hello_roundtrips() {
        let tree = [1u8; 32];
        let token = [2u8; 32];
        let enc = encode_hello(&tree, &token);
        if let Term::Tuple(v) = decode(&enc).unwrap() {
            assert_eq!(v[0].as_atom(), Some("bl"));
            assert_eq!(v[2].as_atom(), Some("hello"));
        } else {
            panic!("not a tuple");
        }
    }

    // our request encoder produces a 5-tuple whose map carries argv, cwd and env
    #[test]
    fn request_encodes_argv_and_cwd() {
        let argv = vec!["eval".to_string(), "(+ 1 2)".to_string()];
        let env = vec![("FOO".to_string(), "bar".to_string())];
        let enc = encode_request(&argv, std::path::Path::new("/tmp"), &[], &env);
        if let Term::Tuple(v) = decode(&enc).unwrap() {
            assert_eq!(v[2].as_atom(), Some("request"));
            // v[4] is the request map
            if let Term::Map(pairs) = &v[4] {
                let has_argv = pairs.iter().any(|(k, _)| k.as_atom() == Some("argv"));
                let has_cwd = pairs.iter().any(|(k, _)| k.as_atom() == Some("cwd"));
                assert!(has_argv && has_cwd);
                let env_pairs = pairs
                    .iter()
                    .find(|(k, _)| k.as_atom() == Some("env"))
                    .and_then(|(_, v)| match v {
                        Term::Map(p) => Some(p.clone()),
                        _ => None,
                    })
                    .expect("the env map must ride on the request");
                assert!(env_pairs.iter().any(|(k, v)| {
                    k.as_bytes() == Some(&b"FOO"[..]) && v.as_bytes() == Some(&b"bar"[..])
                }));
            } else {
                panic!("v[4] not a map");
            }
        } else {
            panic!("not a tuple");
        }
    }

    // int encoding: small (0-255), i32, and boundary
    #[test]
    fn int_roundtrips() {
        for n in [0i64, 5, 42, 255, 256, 1000, -1, -1000, 70000] {
            let mut e = Enc::new();
            e.int(n);
            let bytes = e.finish();
            assert_eq!(decode(&bytes).unwrap().as_int(), Some(n), "int {n}");
        }
    }

    /// A directory that no checkout encloses is still a tree: the daemon keys
    /// itself on the cwd there (`Daemon.start/1`), so a launcher that resolved
    /// nothing could neither find nor hand off to the very daemon the release
    /// had started in that directory.
    #[test]
    fn no_checkout_above_still_resolves_to_a_tree() {
        let scratch = std::env::temp_dir().join(format!("drop-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        let nested = scratch.join("a").join("b");
        std::fs::create_dir_all(&nested).unwrap();

        // Nothing above it is a checkout → the directory IS the tree.
        assert_eq!(
            resolve_root(&nested).unwrap(),
            std::fs::canonicalize(&nested).unwrap()
        );

        // A checkout above it still wins, from any depth below.
        std::fs::create_dir_all(nested.join("priv").join("boot")).unwrap();
        std::fs::write(nested.join("priv/boot/core.bl"), "").unwrap();
        let deep = nested.join("x").join("y");
        std::fs::create_dir_all(&deep).unwrap();
        assert_eq!(
            resolve_root(&deep).unwrap(),
            std::fs::canonicalize(&nested).unwrap()
        );

        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// Silence is a timeout, not a loss — and the client can tell them apart.
    /// Measured cause: a 210s test crossed a hardcoded 30s read timeout, the
    /// socket was healthy the whole time, and the user was told the connection
    /// had been lost.
    #[cfg(unix)]
    #[test]
    fn a_silent_socket_times_out_and_a_closed_one_is_lost() {
        let (mut a, _b) = UnixStream::pair().unwrap();
        a.set_read_timeout(Some(Duration::from_millis(50))).unwrap();
        assert_eq!(recv_frame(&mut a), Err(FrameErr::Timeout), "silence is a timeout");

        let (mut c, d) = UnixStream::pair().unwrap();
        c.set_read_timeout(Some(Duration::from_millis(1_000))).unwrap();
        drop(d);
        assert_eq!(recv_frame(&mut c), Err(FrameErr::Lost), "a closed peer is a loss");
    }

    /// The patience is a knob, and a nonsense value falls back to the default
    /// rather than disabling the guard.
    #[cfg(unix)]
    #[test]
    fn the_read_timeout_is_configurable_but_never_zero() {
        std::env::remove_var("BL_DAEMON_READ_TIMEOUT");
        assert_eq!(read_timeout_secs(), DEFAULT_READ_TIMEOUT_SECS);
        std::env::set_var("BL_DAEMON_READ_TIMEOUT", "42");
        assert_eq!(read_timeout_secs(), 42);
        std::env::set_var("BL_DAEMON_READ_TIMEOUT", "0");
        assert_eq!(
            read_timeout_secs(),
            DEFAULT_READ_TIMEOUT_SECS,
            "zero would mean no guard at all"
        );
        std::env::set_var("BL_DAEMON_READ_TIMEOUT", "soon");
        assert_eq!(read_timeout_secs(), DEFAULT_READ_TIMEOUT_SECS);
        std::env::remove_var("BL_DAEMON_READ_TIMEOUT");
    }

    // ── the transport decision ──────────────────────────────────────────────

    /// A tree can declare its own daemon policy, and the shell can override it.
    /// Before this the declaration was INERT: the transport was chosen before
    /// the project env was applied, so a tree saying `BL_DAEMON=off` was still
    /// served warm — measured 2026-09-16, in a tree that declared exactly that.
    #[test]
    fn the_trees_declaration_is_honoured_and_the_shell_wins() {
        let dir = std::env::temp_dir().join(format!("bl-mode-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("env.bl"),
            ";; a comment mentioning BL_DAEMON is not policy\n{:name \"t\" :env {\"BL_DAEMON\" \"off\"}}\n",
        )
        .unwrap();

        std::env::remove_var("BL_DAEMON");
        assert_eq!(daemon_mode(&dir), DaemonMode::Off, "the tree's word is policy");

        std::env::set_var("BL_DAEMON", "off");
        assert_eq!(daemon_mode(&dir), DaemonMode::Off);

        std::env::set_var("BL_DAEMON", "auto");
        assert_eq!(daemon_mode(&dir), DaemonMode::Auto, "the caller's word wins");
        std::env::remove_var("BL_DAEMON");

        // an unreadable/absent declaration is not an error: auto is the default
        let empty = std::env::temp_dir().join(format!("bl-mode-none-{}", std::process::id()));
        std::fs::create_dir_all(&empty).unwrap();
        assert_eq!(daemon_mode(&empty), DaemonMode::Auto);

        std::fs::remove_dir_all(&dir).ok();
        std::fs::remove_dir_all(&empty).ok();
    }

    /// Prose must not become policy: only a value the transport understands is
    /// accepted, so a sentence in `env.bl` cannot silently disable the daemon.
    #[test]
    fn a_value_that_is_not_a_mode_is_ignored() {
        let dir = std::env::temp_dir().join(format!("bl-mode-junk-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("env.bl"), ":env {\"BL_DAEMON\" \"whenever\"}\n").unwrap();
        std::env::remove_var("BL_DAEMON");
        assert_eq!(daemon_mode(&dir), DaemonMode::Auto);
        std::fs::remove_dir_all(&dir).ok();
    }

}
