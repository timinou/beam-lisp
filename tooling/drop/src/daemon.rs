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
/// release). `BL_DAEMON_ROOT` overrides.
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
            return None;
        }
    }
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
    let _ = stream.set_read_timeout(Some(Duration::from_secs(30)));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    // hello
    let fp = tree_fingerprint(root);
    let hello = encode_hello(&fp, &token);
    if send_frame(&mut stream, &hello).is_err() {
        return Attach::Fallback;
    }

    match recv_frame(&mut stream).and_then(|b| decode(&b)) {
        Some(Term::Tuple(t)) if is_ready(&t) => {}
        Some(Term::Tuple(t)) if is_reject(&t, "restart_required") => return Attach::RestartRequired,
        Some(Term::Tuple(_)) => return Attach::Fallback, // other reject (wrong tree/unauthorized)
        _ => return Attach::Fallback,
    }

    // request — from here, NEVER fall back (side effects may happen).
    let cwd = std::env::current_dir().unwrap_or_else(|_| root.to_path_buf());
    let env_paths = collect_env_paths();
    let req = encode_request(argv, &cwd, &env_paths);
    if send_frame(&mut stream, &req).is_err() {
        return Attach::LostAfterSend;
    }

    stream_until_exit(&mut stream)
}

#[cfg(not(unix))]
pub fn try_attach(_root: &Path, _argv: &[String]) -> Attach {
    Attach::Fallback
}

#[cfg(unix)]
fn stream_until_exit(stream: &mut UnixStream) -> Attach {
    loop {
        let frame = match recv_frame(stream) {
            Some(f) => f,
            None => return Attach::LostAfterSend,
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
                    }
                }
                "stderr" => {
                    if let Some(b) = t.get(5).and_then(|x| x.as_bytes()) {
                        let _ = std::io::stderr().write_all(b);
                        let _ = std::io::stderr().flush();
                    }
                }
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
                    return Attach::Exit(code as i32);
                }
                // {:bl, 1, :failed, id, code, msg} — code is index 4
                "failed" => {
                    let code = t.get(4).and_then(|x| x.as_int()).unwrap_or(1);
                    return Attach::Exit(code as i32);
                }
                "heartbeat" | "accepted" | "watch" => {}
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

#[cfg(unix)]
fn recv_frame(stream: &mut UnixStream) -> Option<Vec<u8>> {
    let mut lenbuf = [0u8; 4];
    stream.read_exact(&mut lenbuf).ok()?;
    let n = u32::from_be_bytes(lenbuf) as usize;
    if n > 64 * 1024 * 1024 {
        return None;
    }
    let mut buf = vec![0u8; n];
    stream.read_exact(&mut buf).ok()?;
    Some(buf)
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

fn encode_request(argv: &[String], cwd: &Path, env_paths: &[String]) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(5);
    e.atom("bl");
    e.small_int(1);
    e.atom("request");
    // 16-byte request id
    let id = request_id();
    e.binary(&id);
    // map %{argv, cwd, env_paths, tty}
    e.map_header(4);
    e.atom("argv");
    e.list_of_binaries(&argv.iter().map(|a| a.as_bytes().to_vec()).collect::<Vec<_>>());
    e.atom("cwd");
    e.binary(cwd.to_string_lossy().as_bytes());
    e.atom("env_paths");
    e.list_of_binaries(&env_paths.iter().map(|p| p.as_bytes().to_vec()).collect::<Vec<_>>());
    e.atom("tty");
    e.map_header(0);
    e.finish()
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

    // our request encoder produces a 5-tuple with argv/cwd
    #[test]
    fn request_encodes_argv_and_cwd() {
        let argv = vec!["eval".to_string(), "(+ 1 2)".to_string()];
        let enc = encode_request(&argv, std::path::Path::new("/tmp"), &[]);
        if let Term::Tuple(v) = decode(&enc).unwrap() {
            assert_eq!(v[2].as_atom(), Some("request"));
            // v[4] is the request map
            if let Term::Map(pairs) = &v[4] {
                let has_argv = pairs.iter().any(|(k, _)| k.as_atom() == Some("argv"));
                let has_cwd = pairs.iter().any(|(k, _)| k.as_atom() == Some("cwd"));
                assert!(has_argv && has_cwd);
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
}
