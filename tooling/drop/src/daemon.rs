// Daemon fast-path for the `bl` launcher.
//
// When a warm VM is running for the caller's tree, the launcher
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

// ── endpoint identity: one VM per tree, or a shared VM per user and build ────

/// The endpoint key the shared VM of a build is named by. A shared VM serves
/// every project that declares `:vm "shared"` (or passes `--shared`), so its key
/// is a constant, not a tree.
pub const SHARED_KEY: &str = "warm";

/// The build id of a source run: the checkout's own code, keyed by its tree.
pub const SRC_BUILD: &str = "src";

/// Whether `build` answers on the shared endpoint for a `shared` request: a
/// source checkout runs its OWN sources and never shares, so it is always keyed
/// by its tree. Mirrors `vm.paths/served-shared?`.
fn served_shared(build: &str, shared: bool) -> bool {
    shared && build != SRC_BUILD
}

/// The key a daemon's files are named by: `warm` when the request is shared and
/// the build is not a source checkout, else the tree id. Sharing is OPT-IN (a
/// project's `:vm "shared"`, or `--shared`), never the build's default: two
/// projects that define a namespace of the same name must not meet in one node.
/// Every endpoint file is `<key>-<build>.<ext>`. Must match
/// `vm.paths/endpoint-key` byte for byte.
pub fn endpoint_key(root: &Path, build: &str, shared: bool) -> String {
    if served_shared(build, shared) {
        SHARED_KEY.to_string()
    } else {
        tree_id(root)
    }
}

/// The 32-byte hello `:tree` field for `root` run by `build`: the checkout's
/// fingerprint when the VM is per-tree (including every source build), the
/// shared constant when it serves every shared project. Must match the release's
/// own `vm.paths`/daemon hello.
pub fn hello_fingerprint(root: &Path, build: &str, shared: bool) -> Vec<u8> {
    if served_shared(build, shared) {
        sha256_bytes(SHARED_KEY.as_bytes())
    } else {
        tree_fingerprint(root)
    }
}

// ── the VM log (must match BeamLisp.Daemon.Paths) ──────────────────────────

/// Directory under the user's state root that holds this app's files.
pub const STATE_APP_DIR: &str = "beam-lisp";
/// Subdirectory of `STATE_APP_DIR` that holds VM logs.
pub const LOG_DIR: &str = "logs";
/// Extension of a VM log file.
pub const LOG_EXT: &str = "log";
/// Extension of a start-in-flight marker (same directory as the socket).
pub const STARTING_EXT: &str = "starting";

/// The user's state root: `$XDG_STATE_HOME` when set and non-empty, else
/// `$HOME/.local/state`. `None` when neither names one — a log path built from
/// nothing would be a lie, and the caller falls back to null streams.
fn state_dir() -> Option<PathBuf> {
    if let Ok(d) = std::env::var("XDG_STATE_HOME") {
        if !d.is_empty() {
            return Some(PathBuf::from(d));
        }
    }
    std::env::var("HOME")
        .ok()
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join(".local/state"))
}

/// The log for `root`'s VM built by `build`:
/// `<state>/beam-lisp/logs/<endpoint-key>-<build>.log`, the same key and build
/// `endpoints_for` names the socket with.
pub fn log_path(root: &Path, build: &str, shared: bool) -> Option<PathBuf> {
    Some(log_path_in(&state_dir()?, &endpoint_key(root, build, shared), build))
}

/// The pure half of `log_path`: one path from its parts, with no environment
/// read, so it is testable without touching the process.
pub fn log_path_in(state_dir: &Path, key: &str, build: &str) -> PathBuf {
    state_dir
        .join(STATE_APP_DIR)
        .join(LOG_DIR)
        .join(format!("{key}-{build}.{LOG_EXT}"))
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
    /// The start-in-flight marker: a VM for this endpoint is being started, so
    /// no second one should be. The VM removes it once it is listening; the
    /// launcher treats one older than `START_GRACE_SECS` as stale.
    pub starting: PathBuf,
}

/// Which build this process is: `BL_BUILD_ID`, cleaned exactly as
/// `vm.paths/build-id` cleans it (lowercase, `[a-z0-9]` only, at most 16),
/// and `src` when unset or empty. The launcher sets it to its payload's sha8
/// before anything else runs (see `main`), so the daemon it starts and every
/// child inherits the same answer.
pub fn build_id() -> String {
    clean_build_id(&std::env::var("BL_BUILD_ID").unwrap_or_default())
}

fn clean_build_id(raw: &str) -> String {
    let clean: String = raw
        .to_ascii_lowercase()
        .chars()
        .filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        .take(16)
        .collect();
    if clean.is_empty() {
        "src".to_string()
    } else {
        clean
    }
}

/// The old, build-less name `<tree-id>.<ext>` that a payload predating
/// build-named daemons binds and looks for. Kept for that payload alone; every
/// current build goes through `endpoints_for`.
fn legacy_endpoints(root: &Path) -> Option<Endpoints> {
    let dir = runtime_dir()?;
    let id = tree_id(root);
    Some(Endpoints {
        sock: dir.join(format!("{id}.sock")),
        token: dir.join(format!("{id}.token")),
        starting: dir.join(format!("{id}.{STARTING_EXT}")),
    })
}

/// The endpoints of the daemon for `root` run by THIS build:
/// `<endpoint-key>-<build>.sock`, where a shared project reaches the build's
/// `warm` VM and an own project (or any source build) is keyed by its tree.
/// Must match `vm.paths/endpoints` byte for byte.
///
/// A payload built before daemons were named by build binds `<tree-id>.sock`,
/// and the launcher running it leaves `BL_BUILD_ID` unset (`names_its_build`),
/// so it looks there instead.
pub fn endpoints(root: &Path, shared: bool) -> Option<Endpoints> {
    match std::env::var("BL_BUILD_ID") {
        Ok(_) => endpoints_for(root, &build_id(), shared),
        Err(_) => legacy_endpoints(root),
    }
}

/// The endpoints for `root` run by `build`, under the user's runtime dir.
pub fn endpoints_for(root: &Path, build: &str, shared: bool) -> Option<Endpoints> {
    Some(endpoints_in(&runtime_dir()?, root, build, shared))
}

/// The pure endpoint set for `root`/`build` under `dir`: every file is
/// `<endpoint-key>-<build>.<ext>`. No environment read, so it tests without
/// touching the process.
pub fn endpoints_in(dir: &Path, root: &Path, build: &str, shared: bool) -> Endpoints {
    let base = format!("{}-{build}", endpoint_key(root, build, shared));
    Endpoints {
        sock: dir.join(format!("{base}.sock")),
        token: dir.join(format!("{base}.token")),
        starting: dir.join(format!("{base}.{STARTING_EXT}")),
    }
}

// ── starting a warm VM (marker + log) ────────────────────────────────────────

/// How long a start marker means "a VM is being started". A marker older than
/// this was left by a start that died before it could delete it, and a new
/// start may take it over. The VM deletes its own marker once it is listening.
pub const START_GRACE_SECS: u64 = 120;

/// Try to claim the right to start the VM for one endpoint. `now_secs` is the
/// clock, passed in so this is pure in its inputs. `create_new` makes the claim
/// atomic, so two commands cannot both start a VM for the same endpoint.
///
/// A marker that already exists means a start is in flight — but only while it
/// is younger than `grace_secs`. An OLDER marker, or one whose contents cannot
/// be read as a unix time, is stale (a start that crashed) and is replaced. An
/// unreadable marker is treated as stale on purpose: a wrong `false` would
/// block this endpoint forever, while a wrong `true` costs one extra start.
pub fn claim_start(marker: &Path, now_secs: u64, grace_secs: u64) -> bool {
    match create_marker(marker, now_secs) {
        Ok(()) => true,
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let held = std::fs::read_to_string(marker).ok().and_then(|s| s.trim().parse::<u64>().ok());
            match held {
                Some(t) if now_secs.saturating_sub(t) < grace_secs => false,
                _ => {
                    let _ = std::fs::remove_file(marker);
                    create_marker(marker, now_secs).is_ok()
                }
            }
        }
        Err(_) => false,
    }
}

/// Create `marker` exclusively, holding `now_secs`. Fails `AlreadyExists` when
/// another claim holds it.
fn create_marker(marker: &Path, now_secs: u64) -> std::io::Result<()> {
    use std::io::Write;
    if let Some(parent) = marker.parent() {
        ensure_dir(parent)?;
    }
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).open(marker)?;
    write!(f, "{now_secs}")
}

/// Create `path` and its parents. Directories holding sockets and logs are 0700
/// on unix: they hold a per-user token.
fn ensure_dir(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(path)
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(path)
    }
}

/// Rotate a log to `<name>.<ext>.1` once it passes `max_bytes`, replacing an
/// older backup. One generation is enough to see what a failed boot printed, and
/// a bounded log never grows without limit.
pub fn rotate_if_large(path: &Path, max_bytes: u64) -> std::io::Result<()> {
    let too_big = std::fs::metadata(path).map(|m| m.len() > max_bytes).unwrap_or(false);
    if !too_big {
        return Ok(());
    }
    let backup = path.with_extension(format!("{LOG_EXT}.1"));
    let _ = std::fs::remove_file(&backup);
    std::fs::rename(path, backup)
}

/// The largest a VM log may grow before it is rotated.
#[cfg(unix)]
const LOG_MAX_BYTES: u64 = 4 * 1024 * 1024;

/// The `--log` argument used when no real log could be opened.
#[cfg(unix)]
const NULL_LOG: &str = "/dev/null";

/// Unix seconds, or 0 before the epoch.
#[cfg(unix)]
fn now_secs() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Open (creating) the VM log for append, with its directory. `None` on any
/// failure: a log that cannot be opened must never stop a VM from starting.
#[cfg(unix)]
fn open_log(path: &Path) -> Option<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    if let Some(parent) = path.parent() {
        ensure_dir(parent).ok()?;
    }
    let _ = rotate_if_large(path, LOG_MAX_BYTES);
    std::fs::OpenOptions::new().append(true).create(true).mode(0o600).open(path).ok()
}

/// Write the one header line that marks a fresh VM start in the log.
#[cfg(unix)]
fn write_log_header(file: &mut std::fs::File, root: &Path) {
    use std::io::Write;
    let _ = writeln!(file, "--- {} bl vm start ({}) ---", now_secs(), root.display());
}

/// Spawn the release's `realm start --foreground [--root <root>|--shared] --log
/// <log>` fully detached, so the VM outlives this launcher. stdout and stderr
/// both land in the SAME log file, so a VM that fails to boot leaves a trace
/// instead of silence in /dev/null; the log is opened here and its path handed to
/// the VM so `bl vm logs` reads the very file this launcher's child writes. When
/// no log can be opened the streams fall back to null — logging must never stop
/// a start. Returns the log path when one was opened.
#[cfg(unix)]
fn start_daemon_detached(bin: &Path, root: &Path, build: &str, shared: bool) -> Option<PathBuf> {
    use std::process::Stdio;
    let log = log_path(root, build, shared);
    let mut file = log.as_deref().and_then(open_log);
    if let Some(f) = file.as_mut() {
        write_log_header(f, root);
    }
    let log_arg = log.clone().unwrap_or_else(|| PathBuf::from(NULL_LOG));
    let mut cmd = release_command(bin);
    cmd.args(warm_start_argv(root, shared, &log_arg)).stdin(Stdio::null());
    // The SAME file feeds stdout and stderr. If it cannot be duplicated it is
    // unusable, so both streams fall back to null together — the one fallback
    // path documented above.
    let dup = file.as_ref().and_then(|f| f.try_clone().ok());
    let opened = dup.is_some();
    match (file, dup) {
        (Some(f), Some(d)) => {
            cmd.stdout(Stdio::from(f)).stderr(Stdio::from(d));
        }
        _ => {
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
        }
    }
    let _ = cmd.spawn();
    if opened {
        log
    } else {
        None
    }
}

/// Walk up from `cwd` to the nearest beam-lisp tree root (checkout or extracted
/// release), falling back to `cwd` itself when no checkout encloses it.
///
/// THE FALLBACK MATCHES THE WARM VM'S OWN RULE. The release keys its server on
/// the root it is given, or `File.cwd!()`; it does not search upward, so a VM
/// started from a scratch directory is keyed on that directory, while a
/// launcher that resolved nothing there would never look for it: no fast-path,
/// no start handoff, a cold VM per command forever. A directory is a tree; a
/// checkout found above it is a better answer to "which tree", which is why the
/// search still comes first. An explicit `--root DIR` is applied by the caller
/// (`tree_root`) and takes precedence over this search.
pub fn resolve_root(cwd: &Path) -> Option<PathBuf> {
    let mut dir = cwd.to_path_buf();
    loop {
        if is_tree_root(&dir) {
            return canonical_or(dir);
        }
        if !dir.pop() {
            return canonical_or(cwd.to_path_buf());
        }
    }
}

/// The tree a command in `cwd` is about: an explicit `--root DIR` wins, else the
/// nearest enclosing tree, canonicalized the same way in both cases.
pub fn tree_root(cwd: &Path, argv: &[String]) -> Option<PathBuf> {
    match root_override(argv) {
        Some(r) => canonical_or(r),
        None => resolve_root(cwd),
    }
}

fn canonical_or(path: PathBuf) -> Option<PathBuf> {
    std::fs::canonicalize(&path).ok().or(Some(path))
}

fn is_tree_root(dir: &Path) -> bool {
    dir.join(TREE_MARKER).exists()
        || (dir.join(LAUNCHER_REL).exists() && dir.join("releases").is_dir())
}

/// The cwd the request frame carries, absolute: the process cwd, unless an
/// explicit `--root DIR` says to act as if the command ran in DIR. That holds in
/// EVERY mode — a shared VM resolves the realm from this cwd, and an own VM
/// serves DIR's tree — so the frame never disagrees with what the user asked
/// for. DIR is canonicalized; if it cannot be, it is passed as written (the
/// release reports a bad path).
pub fn request_cwd(cwd: &Path, argv: &[String]) -> PathBuf {
    match root_override(argv) {
        Some(dir) => std::fs::canonicalize(&dir).unwrap_or(dir),
        None => cwd.to_path_buf(),
    }
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

/// The hello exchange, and the ONE place it is implemented.
#[cfg(unix)]
enum Hello {
    /// Connected and answered ready; the stream is positioned to send a request.
    Ready(UnixStream),
    /// The daemon is up but wants a restart before it will serve this tree.
    RestartRequired,
    /// Unreachable, unusable, or a reject we do not recognise.
    No,
}

/// The build the hello names. Empty for a payload that predates build-named
/// daemons (so its old `<tree>.sock` and tree fingerprint are used); otherwise
/// this process's build id.
#[cfg(unix)]
fn hello_build() -> String {
    std::env::var("BL_BUILD_ID").map(|_| build_id()).unwrap_or_default()
}

#[cfg(unix)]
fn hello(root: &Path, build: &str, shared: bool) -> Hello {
    // A build-named daemon is found under its endpoint key; a payload that
    // predates build-named daemons binds and looks for the old `<tree>.sock`.
    let ep = if build.is_empty() { legacy_endpoints(root) } else { endpoints_for(root, build, shared) };
    let ep = match ep {
        Some(e) => e,
        None => return Hello::No,
    };
    if !ep.sock.exists() {
        return Hello::No;
    }
    let token = match std::fs::read(&ep.token) {
        Ok(t) => t,
        Err(_) => return Hello::No,
    };

    let mut stream = match UnixStream::connect(&ep.sock) {
        Ok(s) => s,
        Err(_) => return Hello::No,
    };
    let _ = stream.set_read_timeout(Some(read_timeout()));
    let _ = stream.set_write_timeout(Some(Duration::from_secs(5)));

    // The legacy payload predates shared VMs and still keys its hello on the
    // tree fingerprint; every current build uses the endpoint-key fingerprint.
    let fp = if build.is_empty() { tree_fingerprint(root) } else { hello_fingerprint(root, build, shared) };
    if send_frame(&mut stream, &encode_hello(&fp, &token, build)).is_err() {
        return Hello::No;
    }

    match recv_frame(&mut stream).ok().and_then(|b| decode(&b)) {
        // PLAN-121/123: the daemon runs each request as its OWN VM process, so
        // it is never "busy" — a ready hello means attach and send.
        Some(Term::Tuple(t)) if is_ready(&t) => Hello::Ready(stream),
        Some(Term::Tuple(t)) if is_reject(&t, "restart_required") => Hello::RestartRequired,
        // any other reject (wrong tree / unauthorized), and a daemon that cannot
        // answer hello within the timeout, are both simply unusable.
        _ => Hello::No,
    }
}

/// Whether a daemon for `root` is up and would serve a request.
///
/// This asks the HELLO and stops there — readiness IS the hello, so nothing has
/// to be requested to ask. That is what keeps it silent: a probe runs in a poll
/// loop inside a caller that is about to print its OWN command's output, and
/// probing with a real command wrote that command's output into the caller.
#[cfg(unix)]
pub fn daemon_ready(root: &Path, shared: bool) -> bool {
    matches!(hello(root, &hello_build(), shared), Hello::Ready(_))
}

#[cfg(unix)]
pub fn try_attach(root: &Path, argv: &[String], shared: bool) -> Attach {
    let mut stream = match hello(root, &hello_build(), shared) {
        Hello::Ready(s) => s,
        Hello::RestartRequired => return Attach::RestartRequired,
        Hello::No => return Attach::Fallback,
    };


    // request — from here, NEVER fall back (side effects may happen).
    let here = std::env::current_dir().unwrap_or_else(|_| root.to_path_buf());
    // The request carries the cwd the command should act in: the process cwd,
    // or `--root DIR`'s realpath. An own VM serves DIR's tree; a shared VM
    // resolves the realm from it — one rule for both modes.
    let cwd = request_cwd(&here, argv);
    let env_paths = collect_env_paths();
    // THE CALLER'S ENVIRONMENT, on the wire. A daemon runs a request in its OWN
    // environment (D17: `FOO=bar bl eval '(System/get_env "FOO")'` answered nil
    // warm and bar cold), which is why serving had to be cut over to `bl serve`
    // and why callers used to force a cold VM. Carrying it here makes a warm run
    // and a cold run the same program, so those workarounds can go back to being
    // performance choices.
    let req = encode_request(argv, &cwd, &env_paths, &collect_env());
    if send_frame(&mut stream, &req).is_err() {
        return Attach::LostAfterSend;
    }

    // Silence is not loss: only our patience ran out. The per-frame read is
    // reset by every frame, including the VM's `heartbeat` (accepted and
    // ignored at the `"heartbeat" | "watch"` arm below), so a timeout here means
    // the VM sent nothing at all — not even its beat — for STALL_TIMEOUT_SECS:
    // it is unresponsive. Saying "connection lost" would be a false diagnosis —
    // measured: a 210s test crossed a 30s timeout that had nothing to do with
    // the connection.

    stream_until_exit(&mut stream)
}

#[cfg(not(unix))]
pub fn try_attach(_root: &Path, _argv: &[String], _shared: bool) -> Attach {
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
            Err(FrameErr::Timeout) => return Attach::Stalled(STALL_TIMEOUT_SECS),
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
                            "bl: the warm VM ended this command with exit {code} and no output; \
                             run it cold (`bl --cold …`) to see why"
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
                        eprintln!("bl: the warm VM refused this command (exit {code})");
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

/// The interval at which the warm VM beats while a request runs, in seconds.
/// This is the CONTRACT with the VM side (`priv/std/vm/net.bl`): if the VM's
/// interval changes, change it here too. A beat resets the client's per-frame
/// read, so it is what keeps a long, silent command from looking lost.
#[cfg(unix)]
const HEARTBEAT_SECS: u64 = 5;

/// How long the client waits for the NEXT frame before calling the warm VM
/// wedged. Because a heartbeat resets the read, silence for this long means not
/// even the heartbeat arrived: the VM is unresponsive, not merely quiet. The
/// fixed 30s of old turned a long command into a false "connection lost"; this
/// deadline is instead well above HEARTBEAT_SECS, so a healthy VM is never
/// declared stalled between beats.
#[cfg(unix)]
const STALL_TIMEOUT_SECS: u64 = 60;

/// The deadline MUST outlast the beat: a heartbeat is what resets the read, so a
/// deadline shorter than the interval would declare a healthy VM wedged between
/// beats. Enforced here and in `the_stall_timeout_outlasts_the_daemons_heartbeat`.
#[cfg(unix)]
const _: () = assert!(STALL_TIMEOUT_SECS > HEARTBEAT_SECS);

#[cfg(unix)]
fn read_timeout() -> Duration {
    Duration::from_secs(STALL_TIMEOUT_SECS)
}

#[cfg(unix)]
fn recv_frame(stream: &mut UnixStream) -> Result<Vec<u8>, FrameErr> {
    let mut lenbuf = [0u8; 4];
    read_exact_classified(stream, &mut lenbuf)?;
    let n = u32::from_be_bytes(lenbuf) as usize;
    if n > MAX_FRAME_BYTES {
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

/// `{:bl 1 :hello %{tree token build}}`: `build` names the build this client
/// expects to reach; a daemon running another one answers `:restart_required`.
fn encode_hello(tree: &[u8], token: &[u8], build: &str) -> Vec<u8> {
    let mut e = Enc::new();
    e.tuple_header(4);
    e.atom("bl");
    e.small_int(1);
    e.atom("hello");
    // An empty build is a payload that predates build-named daemons: its
    // hello is the two-key one it understands.
    e.map_header(if build.is_empty() { 2 } else { 3 });
    e.atom("tree");
    e.binary(tree);
    e.atom("token");
    e.binary(token);
    if !build.is_empty() {
        e.atom("build");
        e.binary(build.as_bytes());
    }
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

/// The largest frame the client will read (64 MiB): a bound on a hostile or
/// buggy peer, so a bogus length cannot make us allocate without limit.
const MAX_FRAME_BYTES: usize = 64 * 1024 * 1024;

/// The environment we send, bounded: 1024 names and 64 KiB per value is far
/// above any real shell (a PATH with 200 entries is ~10 KiB), and keeps one
/// frame from straining the daemon.
const MAX_VARS: usize = 1024;
const MAX_VALUE: usize = 64 * 1024;

/// The environment to send: the caller's, bounded.
///
/// Bounded because the frame is one term and a hostile environment should not
/// be able to make the daemon allocate without limit; 1024 names and 64 KiB per
/// value is far above any real shell (a PATH with 200 entries is ~10 KiB).
fn collect_env() -> Vec<(String, String)> {
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

// ── the transport decision lives in transport.rs ────────────────────────────
// (`Transport`, `transport_from`, `start_requested`). The tree's and the
// config's `:warm` declarations are scanned there, never evaluated here.

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
        let enc = encode_hello(&tree, &token, "3ffa4c3a");
        if let Term::Tuple(v) = decode(&enc).unwrap() {
            assert_eq!(v[0].as_atom(), Some("bl"));
            assert_eq!(v[2].as_atom(), Some("hello"));
            let Term::Map(pairs) = &v[3] else { panic!("hello payload is not a map") };
            let build = pairs
                .iter()
                .find(|(k, _)| k.as_atom() == Some("build"))
                .and_then(|(_, v)| v.as_bytes())
                .expect("the hello must name the build it expects");
            assert_eq!(build, &b"3ffa4c3a"[..]);
        } else {
            panic!("not a tuple");
        }
    }

    /// The build id is cleaned the way `vm.paths/build-id` cleans it, so the two
    /// sides name the same file.
    #[test]
    fn build_id_is_cleaned_like_vm_paths() {
        assert_eq!(clean_build_id(""), "src");
        assert_eq!(clean_build_id("3FFA4C3A"), "3ffa4c3a");
        assert_eq!(clean_build_id("../x y"), "xy");
        assert_eq!(clean_build_id("!!!"), "src");
        assert_eq!(clean_build_id("0123456789abcdef0123"), "0123456789abcdef");
    }

    /// A payload that predates build-named daemons gets the two-key hello.
    #[test]
    fn a_legacy_hello_has_no_build() {
        let enc = encode_hello(&[1u8; 32], &[2u8; 32], "");
        let Term::Tuple(v) = decode(&enc).unwrap() else { panic!("not a tuple") };
        let Term::Map(pairs) = &v[3] else { panic!("not a map") };
        assert_eq!(pairs.len(), 2);
        assert!(pairs.iter().all(|(k, _)| k.as_atom() != Some("build")));
    }

    /// Sharing is OPT-IN: an own drop build is keyed by its tree like any other
    /// per-tree VM, so two roots are two files — golden
    /// `<tree-id>-a238fa91.sock`.
    #[test]
    fn an_own_drop_build_endpoint_is_per_tree() {
        let rt = Path::new("/run/beam_lisp");
        let a = endpoints_in(rt, Path::new("/tmp/proj"), "a238fa91", false);
        let b = endpoints_in(rt, Path::new("/some/other/project"), "a238fa91", false);
        let tree = tree_id(Path::new("/tmp/proj"));
        assert!(a.sock.to_string_lossy().ends_with(&format!("/{tree}-a238fa91.sock")));
        assert!(a.token.to_string_lossy().ends_with(&format!("/{tree}-a238fa91.token")));
        assert!(a.starting.to_string_lossy().ends_with(&format!("/{tree}-a238fa91.starting")));
        assert_ne!(a.sock, b.sock, "two roots are two endpoints");
        assert_ne!(a.token, b.token);
        assert_ne!(a.starting, b.starting);
    }

    /// A DECLARED shared drop build is one endpoint for every project: golden
    /// `warm-a238fa91.sock`, identical for two roots. The bl side
    /// (`vm.paths/endpoints`) pins the same string.
    #[test]
    fn a_shared_drop_build_endpoint_is_shared_across_roots() {
        let rt = Path::new("/run/beam_lisp");
        let a = endpoints_in(rt, Path::new("/tmp/proj"), "a238fa91", true);
        let b = endpoints_in(rt, Path::new("/some/other/project"), "a238fa91", true);
        assert!(a.sock.to_string_lossy().ends_with("/warm-a238fa91.sock"));
        assert!(a.token.to_string_lossy().ends_with("/warm-a238fa91.token"));
        assert!(a.starting.to_string_lossy().ends_with("/warm-a238fa91.starting"));
        assert_eq!(a.sock, b.sock, "one shared build, every project: the same endpoint");
        assert_eq!(a.token, b.token);
        assert_eq!(a.starting, b.starting);
    }

    /// Two builds are two daemons even when both are shared, so the build is
    /// still part of the name.
    #[test]
    fn two_shared_drop_builds_are_two_endpoints() {
        let rt = Path::new("/run/beam_lisp");
        let a = endpoints_in(rt, Path::new("/tmp/proj"), "a238fa91", true);
        let b = endpoints_in(rt, Path::new("/tmp/proj"), "5e0dd11f", true);
        assert_ne!(a.sock, b.sock);
        assert_ne!(a.token, b.token);
        assert_ne!(a.starting, b.starting);
    }

    /// A source build runs a checkout's own code, so it stays keyed by the tree
    /// id even when asked to share: one endpoint per checkout, golden
    /// `<tree-id>-src.sock`.
    #[test]
    fn a_source_build_endpoint_carries_the_tree_even_shared() {
        let rt = Path::new("/run/beam_lisp");
        let root = Path::new("/tmp/proj");
        let tree = tree_id(root);
        for shared in [false, true] {
            let a = endpoints_in(rt, root, SRC_BUILD, shared);
            assert!(a.sock.to_string_lossy().ends_with(&format!("/{tree}-src.sock")));
            assert!(a.token.to_string_lossy().ends_with(&format!("/{tree}-src.token")));
            assert!(a.starting.to_string_lossy().ends_with(&format!("/{tree}-src.starting")));
        }
    }

    /// The hello `:tree` field follows the same split: an own VM checks its
    /// checkout, a shared one checks the constant, and a source build checks its
    /// checkout even when shared.
    #[test]
    fn the_hello_fingerprint_is_shared_only_for_a_shared_drop_build() {
        let a = hello_fingerprint(Path::new("/tmp/proj"), "a238fa91", false);
        let b = hello_fingerprint(Path::new("/another/tree"), "a238fa91", false);
        assert_ne!(a, b, "an own build is keyed by its tree");
        assert_eq!(a, tree_fingerprint(Path::new("/tmp/proj")));

        let c = hello_fingerprint(Path::new("/tmp/proj"), "a238fa91", true);
        let d = hello_fingerprint(Path::new("/another/tree"), "a238fa91", true);
        assert_eq!(c, d, "one shared build serves every project");
        assert_eq!(c, sha256_bytes(SHARED_KEY.as_bytes()));

        let e = hello_fingerprint(Path::new("/tmp/proj"), SRC_BUILD, true);
        assert_eq!(e, tree_fingerprint(Path::new("/tmp/proj")), "a source build never shares");
    }

    /// A VM log's path is built from its parts alone — no environment read. A
    /// shared build's log is shared like its socket: golden `warm-a238fa91.log`.
    #[test]
    fn a_log_path_names_the_key_the_build_and_the_state_root() {
        assert_eq!(
            log_path_in(Path::new("/state"), SHARED_KEY, "a238fa91"),
            PathBuf::from("/state/beam-lisp/logs/warm-a238fa91.log")
        );
    }

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("drop-log-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    /// `create_new` makes the first claim win and a live marker refuse a second;
    /// once the grace passes, the marker is stale and may be taken over.
    #[test]
    fn a_fresh_marker_wins_and_a_live_one_blocks() {
        let d = scratch("claim");
        let m = d.join("e.starting");
        assert!(claim_start(&m, 1_000, 120), "the first claim wins");
        assert!(!claim_start(&m, 1_001, 120), "a live marker refuses a second claim");
        assert_eq!(std::fs::read_to_string(&m).unwrap(), "1000");
        assert!(!claim_start(&m, 1_119, 120), "still inside the grace");
        assert!(claim_start(&m, 1_120, 120), "at the grace the marker is stale");
        assert_eq!(std::fs::read_to_string(&m).unwrap(), "1120", "the stale marker is replaced");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A marker whose time cannot be read must not block the endpoint forever.
    #[test]
    fn an_unreadable_marker_is_treated_as_stale() {
        let d = scratch("unreadable");
        let m = d.join("e.starting");
        std::fs::write(&m, "not-a-time").unwrap();
        assert!(claim_start(&m, 500, 120), "junk cannot be trusted to mean a live start");
        assert_eq!(std::fs::read_to_string(&m).unwrap(), "500");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Rotation keeps one generation: a log at the limit is untouched, a larger
    /// one is renamed to `.log.1`, and an older backup is replaced.
    #[test]
    fn rotate_if_large_keeps_one_generation() {
        let d = scratch("rotate");
        let log = d.join("x.log");
        let backup = d.join("x.log.1");

        std::fs::write(&log, vec![b'a'; 100]).unwrap();
        rotate_if_large(&log, 100).unwrap();
        assert!(log.exists(), "a log at the limit is not rotated");
        assert!(!backup.exists());

        std::fs::write(&log, vec![b'b'; 101]).unwrap();
        rotate_if_large(&log, 100).unwrap();
        assert!(!log.exists(), "a log past the limit is moved aside");
        assert_eq!(std::fs::read(&backup).unwrap(), vec![b'b'; 101]);

        std::fs::write(&log, vec![b'c'; 200]).unwrap();
        rotate_if_large(&log, 100).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), vec![b'c'; 200], "the older backup is replaced");
        let _ = std::fs::remove_dir_all(&d);
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
        std::fs::write(nested.join(TREE_MARKER), "").unwrap();
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

    /// The stall deadline must sit well above the VM's heartbeat: a beat resets
    /// the per-frame read, so if the deadline were shorter than the interval a
    /// healthy VM would be declared unresponsive between beats. This is the
    /// CONTRACT with `priv/std/vm/net.bl`.
    #[cfg(unix)]
    #[test]
    fn the_stall_timeout_outlasts_the_daemons_heartbeat() {
        assert!(HEARTBEAT_SECS > 0, "a VM that never beats cannot keep the read alive");
        assert!(
            STALL_TIMEOUT_SECS > HEARTBEAT_SECS,
            "a heartbeat must reset the read before the stall deadline fires"
        );
        assert_eq!(read_timeout(), Duration::from_secs(STALL_TIMEOUT_SECS));
    }

    /// `--root DIR` outranks the upward search, and an override with no value is
    /// simply absent — the release reports the usage error.
    #[test]
    fn an_explicit_root_override_beats_the_search() {
        let scratch = std::env::temp_dir().join(format!("drop-tree-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        let deep = scratch.join("a").join("b");
        std::fs::create_dir_all(&deep).unwrap();

        let a = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        let root = std::fs::canonicalize(&scratch).unwrap();
        assert_eq!(tree_root(&deep, &a(&["--root", &root.to_string_lossy(), "run"])), Some(root.clone()));
        assert_eq!(tree_root(&deep, &a(&["run"])), std::fs::canonicalize(&deep).ok());
        assert_eq!(tree_root(&deep, &a(&["--root"])), std::fs::canonicalize(&deep).ok(), "no value, no override");

        let _ = std::fs::remove_dir_all(&scratch);
    }

    /// `--root DIR` sets the request cwd to DIR's realpath in EVERY mode; no
    /// override keeps the process cwd, and a valueless `--root` is not one.
    #[test]
    fn root_override_sets_the_request_cwd_in_every_mode() {
        let d = std::env::temp_dir().join(format!("drop-request-cwd-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let dir = std::fs::canonicalize(&d).unwrap();
        let here = Path::new("/home/somewhere");
        let a = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<_>>();

        let with_root = a(&["--root", &dir.to_string_lossy(), "run"]);
        assert_eq!(request_cwd(here, &with_root), dir, "an override acts in DIR");
        assert_eq!(request_cwd(here, &a(&["run"])), here, "no override, process cwd");
        assert_eq!(request_cwd(here, &a(&["--root"])), here, "no value, no override");

        let _ = std::fs::remove_dir_all(&d);
    }
}
