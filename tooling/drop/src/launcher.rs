//! `drop-launcher` — the self-extracting entry of a bundled `bl`.
//! File layout: [launcher][payload.tar.gz][trailer].
//! Runtime contract: docs/native-bundler.md §6.

#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Command;

include!("common.rs");
include!("daemon.rs");
include!("store.rs");
include!("builder.rs");
include!("hooks.rs");

const EXIT_LAUNCHER_FAILURE: i32 = 126;

/// The index of the first non-flag token in `argv` — the VERB — skipping the
/// values that belong to a flag (`VALUED`). `None` when argv names no verb.
///
/// Global flags may precede the command (`bl -p lib run x.bl`), so the verb is
/// not simply `argv[0]` — deciding the daemon fast-path on the first token would
/// send `bl -p lib repl` to the daemon, where it would hold the single worker
/// forever. `--` is skipped too: everything after it is the program's argv.
fn verb_index(argv: &[String]) -> Option<usize> {
    const VALUED: [&str; 8] = [
        "-p",
        "--path",
        "--code-path",
        "-o",
        "--out",
        "--tier",
        "--jobs",
        "--port",
    ];
    let mut i = 0;
    while i < argv.len() {
        let a = argv[i].as_str();
        if a == "--" {
            i += 1;
            continue;
        }
        if a.starts_with('-') && a != "-" {
            if VALUED.contains(&a) {
                i += 2;
            } else {
                i += 1;
            }
            continue;
        }
        // An empty token names nothing: it is a quoting accident, not a verb.
        if a.is_empty() {
            i += 1;
            continue;
        }
        return Some(i);
    }
    None
}

fn verb_of(argv: &[String]) -> Option<String> {
    verb_index(argv).map(|i| argv[i].clone())
}

/// Is this invocation the REQUEST to start the daemon — `bl daemon start`?
/// Only the explicit subcommand counts: a bare `bl daemon` is `status`.
fn daemon_start_requested(argv: &[String]) -> bool {
    match verb_index(argv) {
        Some(i) => argv[i] == "daemon" && argv.get(i + 1).map(String::as_str) == Some("start"),
        None => false,
    }
}

// ── tests: the daemon fast-path's verb detection ────────────────────────────
#[cfg(test)]
mod verb_tests {
    use super::{daemon_start_requested, verb_of};

    fn v(args: &[&str]) -> Option<String> {
        verb_of(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn verb_is_the_first_non_flag_token() {
        assert_eq!(v(&["run", "x.bl"]).as_deref(), Some("run"));
        assert_eq!(v(&["--json", "check"]).as_deref(), Some("check"));
        assert_eq!(v(&["-p", "lib", "repl"]).as_deref(), Some("repl"));
        assert_eq!(v(&["--code-path", "beams", "--json", "ask", "impact"]).as_deref(), Some("ask"));
        assert_eq!(v(&["-o", "out"]).as_deref(), None);
        assert_eq!(v(&["", "lint"]).as_deref(), Some("lint"));
    }

    #[test]
    fn empty_and_flags_only_have_no_verb() {
        assert_eq!(v(&[]), None);
        assert_eq!(v(&["--json"]), None);
        assert_eq!(v(&["-p"]), None);
        assert_eq!(v(&["--"]), None);
    }

    /// `bl daemon start` is the one invocation the launcher answers ITSELF:
    /// it detaches the VM and returns. Every other daemon word (`status`,
    /// `stop`, and the bare verb, which means `status`) must still reach the
    /// release — and a `daemon` that merely appears as an ARGUMENT of another
    /// verb is not a daemon invocation at all.
    #[test]
    fn only_an_explicit_daemon_start_is_the_launchers_own_work() {
        let ds = |args: &[&str]| {
            daemon_start_requested(&args.iter().map(|s| s.to_string()).collect::<Vec<_>>())
        };

        assert!(ds(&["daemon", "start"]));
        assert!(ds(&["-p", "lib", "daemon", "start"]));
        assert!(ds(&["--json", "daemon", "start"]));

        assert!(!ds(&["daemon"]), "a bare `bl daemon` is `status`");
        assert!(!ds(&["daemon", "status"]));
        assert!(!ds(&["daemon", "stop"]));
        assert!(!ds(&["run", "daemon", "start"]), "an argument, not the verb");
        assert!(!ds(&[]));
    }
}

fn fail(msg: &str) -> ! {
    eprintln!("drop: {msg}");
    std::process::exit(EXIT_LAUNCHER_FAILURE)
}


/// Read the payload slice, VERIFY its sha256 against the trailer, and extract.
/// Only called on first run for a given sha8 (the version dir is missing).
fn verify_and_extract_from(file: &std::path::Path, t: &Trailer, dest: &std::path::Path, install: &std::path::Path) {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(file)
        .unwrap_or_else(|e| fail(&format!("cannot read {}: {e}", file.display())));
    f.seek(SeekFrom::Start(t.offset)).expect("seek");
    let mut payload = vec![0u8; t.len as usize];
    f.read_exact(&mut payload).expect("read payload");

    let want = hex(&t.sha256);
    let got = sha256_hex(&payload);
    if got != want {
        fail(&format!("payload corrupt (sha256 {got} != {want}) — re-download"));
    }

    std::fs::create_dir_all(install)
        .unwrap_or_else(|e| fail(&format!("cannot create install dir {}: {e}", install.display())));
    extract_tar_gz(&payload, dest)
        .unwrap_or_else(|e| fail(&format!("first-run extraction failed: {e}")));
}

/// Hours an unreferenced, unused build is kept before it is swept. Override
/// with `BL_DROP_GRACE_HOURS`.
///
/// Why a grace at all: a VM execs helper binaries (`inet_gethost`,
/// `erl_child_setup`) out of its OWN erts dir, lazily, and a daemon runs from
/// its tree for its whole life. Deleting a tree some process still runs from
/// kills it with
///
///     Can not execute .../drop/<sha8>/erts-<v>/bin/inet_gethost : enoent
///
/// so a tree is only ever swept when nothing points at it, no daemon runs it,
/// no process runs from it (`/proc/*/exe` and `maps`), and it has not been
/// used for the grace period.
const DEFAULT_GRACE_HOURS: u64 = 24;

/// Days a build that nothing points at is kept after its last use: a build run
/// by an explicit path (`./bl`, a tool's pinned runtime) has no pointer, and
/// is kept while it keeps being used. Override with `BL_DROP_KEEP_DAYS`.
const DEFAULT_RECENT_DAYS: u64 = 14;

/// A whole-number setting from the environment (hours or days, by name).
fn hours_env(name: &str, default: u64) -> u64 {
    std::env::var(name).ok().and_then(|v| v.trim().parse().ok()).unwrap_or(default)
}

/// `<sha8>.tmp-<pid>` is what an extraction unpacks into before it publishes.
/// One that outlives its extractor means the process died mid-unpack (a reboot,
/// a `kill -9`), and it is ~100 MB of nothing. An extraction takes seconds, so a
/// day-old staging dir is debris by any measure while a live one is never in
/// reach.
const TMP_KEEP_HOURS: u64 = 24;

/// Why a build is kept.
#[derive(Debug, PartialEq, Eq)]
pub enum Keep {
    InUse,
    Pointed(String),
    Daemon,
    Running,
    Recent,
    Undated,
}

/// What the store refers to: build id → the first pointer naming it. A
/// bleeding-edge or source pointer whose worktree no longer exists holds
/// nothing (that is how a deleted worktree's builds become collectable).
pub fn referenced(store: &Store) -> std::collections::HashMap<String, String> {
    let mut refs = std::collections::HashMap::new();
    for dir in ["channels", "tags", "bleeding-edge", "sources"] {
        for (name, p) in list(store, dir) {
            let alive = match p.get("root") {
                Some(root) if dir == "bleeding-edge" || dir == "sources" => Path::new(root).exists(),
                _ => true,
            };
            if alive {
                refs.entry(p.build.clone()).or_insert(format!("{dir}/{name}"));
            }
        }
    }
    refs
}

/// Build ids a live daemon serves, from the runtime dir's `<tree>-<build>.sock`.
fn daemon_builds() -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    let Some(dir) = runtime_dir() else { return out };
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().into_owned();
            if let Some((_, b)) = n.strip_suffix(".sock").and_then(|s| s.rsplit_once('-')) {
                out.insert(b.to_string());
            }
        }
    }
    out
}

/// Build ids some process runs from: an executable or a mapped file under
/// `<install>/<id>/`. Linux only; elsewhere nothing is known to run.
fn running_builds(install: &Path) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    let prefix = format!("{}/", install.display());
    let Ok(rd) = std::fs::read_dir("/proc") else { return out };
    let mut note = |s: &str| {
        if let Some(id) = s.strip_prefix(&prefix).and_then(|r| r.split('/').next()) {
            if is_build_id(id) {
                out.insert(id.to_string());
            }
        }
    };
    for e in rd.flatten() {
        if !e.file_name().to_string_lossy().bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let p = e.path();
        if let Ok(exe) = std::fs::read_link(p.join("exe")) {
            note(&exe.to_string_lossy());
        }
        if let Ok(maps) = std::fs::read_to_string(p.join("maps")) {
            for line in maps.lines() {
                if let Some(i) = line.find(&prefix) {
                    note(&line[i..]);
                }
            }
        }
    }
    out
}

/// When build `dir` was last used: its `.last-used` stamp, else the dir's mtime.
fn last_used(dir: &Path) -> Option<std::time::SystemTime> {
    std::fs::metadata(dir.join(".last-used"))
        .or_else(|_| std::fs::metadata(dir))
        .and_then(|m| m.modified())
        .ok()
}

/// Record that build `dir` is used now, at most once an hour (one stat per
/// run; the write is rare).
fn touch_used(dir: &Path) {
    let stamp = dir.join(".last-used");
    let fresh = std::fs::metadata(&stamp)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.elapsed().ok())
        .is_some_and(|age| age < std::time::Duration::from_secs(3_600));
    if !fresh {
        let _ = std::fs::write(&stamp, b"");
    }
}

/// The facts one GC pass decides from.
pub struct GcFacts {
    pub in_use: String,
    pub refs: std::collections::HashMap<String, String>,
    pub daemons: std::collections::HashSet<String>,
    pub running: std::collections::HashSet<String>,
    pub now: std::time::SystemTime,
    pub grace: std::time::Duration,
    pub recent: std::time::Duration,
}

/// Why build `id` stays, or None when it may go. Pure in its facts.
pub fn keep_reason(id: &str, used: Option<std::time::SystemTime>, f: &GcFacts) -> Option<Keep> {
    if id == f.in_use {
        return Some(Keep::InUse);
    }
    if let Some(why) = f.refs.get(id) {
        return Some(Keep::Pointed(why.clone()));
    }
    if f.daemons.contains(id) {
        return Some(Keep::Daemon);
    }
    if f.running.contains(id) {
        return Some(Keep::Running);
    }
    let Some(t) = used else { return Some(Keep::Undated) };
    let age = f.now.duration_since(t).unwrap_or_default();
    (age < f.recent.max(f.grace)).then_some(Keep::Recent)
}

/// One entry of a GC pass: the dir, and why it stays (None = it goes).
pub struct GcRow {
    pub name: String,
    pub keep: Option<Keep>,
}

/// Sweep the install dir by reference. Only `<sha8>` build dirs and stale
/// `<sha8>.tmp-<pid>` staging dirs are ever candidates; anything else there
/// (the `store/` itself) is never touched. With `dry_run`, nothing is removed.
pub fn gc_by_reference(install: &Path, in_use: &str, dry_run: bool) -> Vec<GcRow> {
    let store = Store { root: install.to_path_buf() };
    let facts = GcFacts {
        in_use: in_use.to_string(),
        refs: referenced(&store),
        daemons: daemon_builds(),
        running: running_builds(install),
        now: std::time::SystemTime::now(),
        grace: std::time::Duration::from_secs(hours_env("BL_DROP_GRACE_HOURS", DEFAULT_GRACE_HOURS) * 3_600),
        recent: std::time::Duration::from_secs(hours_env("BL_DROP_KEEP_DAYS", DEFAULT_RECENT_DAYS) * 86_400),
    };
    let tmp_window = std::time::Duration::from_secs(TMP_KEEP_HOURS * 3_600);

    let mut rows = vec![];
    let Ok(rd) = std::fs::read_dir(install) else { return rows };
    for d in rd.flatten() {
        let name = d.file_name().to_string_lossy().into_owned();
        let path = d.path();
        if !path.is_dir() {
            continue;
        }
        let keep = if let Some((id, _)) = name.split_once(".tmp-") {
            if !is_build_id(id) {
                continue;
            }
            match last_used(&path).and_then(|t| facts.now.duration_since(t).ok()) {
                Some(a) if a >= tmp_window => None,
                _ => Some(Keep::Recent),
            }
        } else if is_build_id(&name) {
            keep_reason(&name, last_used(&path), &facts)
        } else {
            continue;
        };
        if keep.is_none() && !dry_run {
            let _ = std::fs::remove_dir_all(&path);
        }
        rows.push(GcRow { name, keep });
    }
    rows.sort_by(|a, b| a.name.cmp(&b.name));
    rows
}

/// The launcher's own GC after a first extraction: quiet, and never removes the
/// build it is about to run.
fn gc_old_versions(install: &std::path::Path, keep: &str) {
    let _ = gc_by_reference(install, keep, false);
}

/// `bl self-gc [--dry-run]`: what the store holds, and why each build stays.
fn self_gc(args: &[String]) -> Result<String, String> {
    fn du(p: &Path) -> u64 {
        match std::fs::symlink_metadata(p) {
            Ok(m) if m.is_dir() => std::fs::read_dir(p).map(|rd| rd.flatten().map(|e| du(&e.path())).sum()).unwrap_or(0),
            Ok(m) => m.len(),
            Err(_) => 0,
        }
    }
    let dry = args.iter().any(|a| a == "--dry-run");
    let install = install_dir();
    let sizes: std::collections::HashMap<String, u64> = std::fs::read_dir(&install)
        .map(|rd| rd.flatten().map(|e| (e.file_name().to_string_lossy().into_owned(), du(&e.path()))).collect())
        .unwrap_or_default();
    let rows = gc_by_reference(&install, "", dry);
    let (mut out, mut freed, mut kept) = (vec![], 0u64, 0u64);
    for r in &rows {
        let size = sizes.get(&r.name).copied().unwrap_or(0);
        let why = match &r.keep {
            None => {
                freed += size;
                (if dry { "would remove" } else { "removed" }).to_string()
            }
            Some(k) => {
                kept += size;
                match k {
                    Keep::Pointed(p) => format!("kept: {p}"),
                    Keep::InUse => "kept: in use".to_string(),
                    Keep::Daemon => "kept: a daemon runs it".to_string(),
                    Keep::Running => "kept: a process runs from it".to_string(),
                    Keep::Recent => "kept: used recently".to_string(),
                    Keep::Undated => "kept: cannot tell when it was used".to_string(),
                }
            }
        };
        out.push(format!("{:<24} {:>6} MB  {why}", r.name, size / 1_048_576));
    }
    out.push(format!(
        "{} {} MB, keeping {} MB",
        if dry { "would free" } else { "freed" },
        freed / 1_048_576,
        kept / 1_048_576
    ));
    Ok(out.join("\n"))
}

fn maintenance(argv: &[String], t: &Trailer, sha8: &str) -> ! {
    match argv.first().map(String::as_str) {
        Some("directory") => {
            println!("{}", install_dir().display());
            std::process::exit(0)
        }
        Some("meta") => {
            println!("format: DRP{FORMAT_VERSION}");
            println!("payload-sha256: {sha8}…");
            println!("target: {}", target_name(t.os, t.arch));
            println!("install: {}", install_dir().display());
            std::process::exit(0)
        }
        Some("uninstall") => {
            let dir = install_dir();
            std::fs::remove_dir_all(&dir)
                .unwrap_or_else(|e| fail(&format!("cannot remove {}: {e}", dir.display())));
            println!("removed {}", dir.display());
            std::process::exit(0)
        }
        _ => {
            eprintln!("usage: bl maintenance directory|meta|uninstall");
            std::process::exit(2)
        }
    }
}

/// Try the warm daemon. Returns `Some(exit_code)` when the command was served
/// (or lost after send — unknown outcome, exit 1), or `None` to fall back to a
/// cold `bin/bl` boot. With `BL_DAEMON=auto`, a missing daemon is auto-started
/// from `bin/bl daemon start` (detached) and retried once.

/// `bl` is THIS executable — the launcher. The release's own `bin/bl` is a
/// different program with a different command surface (`start`, `daemon`,
/// `eval`, `rpc`), and its path changes with every rebuild. So anything that
/// has to re-invoke `bl` from inside a running one — a gateway detaching
/// itself, a systemd unit's ExecStart — is handed this path as `BL_BIN`,
/// instead of looking up `bl` on a PATH where, inside a drop, the first match
/// can be the release script itself.
///
/// The failure it prevents, seen for real: `bl gateway start` in an installed
/// drop detached `setsid <payload>/bin/bl gateway run`, and the release script
/// answered `Usage: bl COMMAND … ERROR: Unknown command gateway`.
fn self_bl() -> std::path::PathBuf {
    std::env::current_exe().unwrap_or_else(|_| std::path::PathBuf::from("bl"))
}

/// After a request has been SENT, only three outcomes are safe: the command
/// finished, the connection was lost, or nothing came back while it was still
/// running. `None` means the daemon was never reached, which is the only case
/// where the caller may fall back to a cold exec — and a stall must NOT take it,
/// because the daemon's copy of the command may still be running. Running it
/// twice is worse than reporting an unknown outcome.
fn after_attach(a: Attach) -> Option<i32> {
    match a {
        Attach::Exit(code) => Some(code),
        Attach::LostAfterSend => {
            eprintln!("bl: daemon connection lost mid-command; outcome unknown");
            Some(1)
        }
        Attach::Stalled(secs) => {
            eprintln!(
                "bl: the daemon has sent nothing for {secs}s, but the connection is still open \
                 — the command is probably still running, and it is NOT re-run here \
                 (outcome unknown). Raise BL_DAEMON_READ_TIMEOUT to wait longer, or run it \
                 cold with BL_DAEMON=off to see it through."
            );
            Some(1)
        }
        _ => None,
    }
}

fn maybe_attach_daemon(argv: &[String], bin: &std::path::Path) -> Option<i32> {
    let cwd = std::env::current_dir().ok()?;
    let root = resolve_root(&cwd)?;

    match try_attach(&root, argv) {
        Attach::Exit(code) => Some(code),
        a @ (Attach::LostAfterSend | Attach::Stalled(_)) => after_attach(a),
        Attach::RestartRequired => {
            // the daemon is stale (checkout changed). Stop it, restart, retry once.
            // Say so: a daemon that vanishes without a word looks like a command
            // that failed for no reason, and the next command pays a cold boot.
            eprintln!(
                "bl: the daemon for this tree was started from a different build; \
                 stopping it and running this command cold"
            );
            let _ = std::process::Command::new(bin)
                .arg("eval")
                .arg("BeamLisp.Ns.Bl.Cli.main([\"daemon\",\"stop\"])")
                .env("BL_DAEMON_ROOT", &root)
                .env("BL_BIN", self_bl())
                .status();
            if autostart_enabled() {
                start_daemon_detached(bin, &root);
                if wait_ready(&root) {
                    return match try_attach(&root, argv) {
                        Attach::Exit(code) => Some(code),
                        other => after_attach(other),
                    };
                }
            }
            None
        }
        Attach::Fallback => {
            if autostart_enabled() {
                start_daemon_detached(bin, &root);
                if wait_ready(&root) {
                    return match try_attach(&root, argv) {
                        Attach::Exit(code) => Some(code),
                        other => after_attach(other),
                    };
                }
            }
            None
        }
    }
}

#[cfg(unix)]
fn autostart_enabled() -> bool {
    std::env::var("BL_DAEMON").map(|v| v == "auto").unwrap_or(false)
}

/// Spawn `bin/bl daemon start` fully detached so it outlives this launcher.
#[cfg(unix)]
fn start_daemon_detached(bin: &std::path::Path, root: &std::path::Path) {
    use std::process::Stdio;
    let _ = std::process::Command::new(bin)
        .arg("eval")
        .arg("BeamLisp.Ns.Bl.Cli.main([\"daemon\",\"start\"])")
        .env("BL_DAEMON_ROOT", root)
        .env("BL_BIN", self_bl())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// Poll for an authenticated-reachable daemon, up to a startup deadline.
#[cfg(unix)]
fn wait_ready(root: &std::path::Path) -> bool {
    for _ in 0..600 {
        // 600 * 200ms = 120s
        if daemon_ready(root) {
            return true;
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    false
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let me = std::env::current_exe().unwrap_or_else(|_| fail("cannot locate myself"));

    // TWO MODES, told apart by the file itself. A DROP carries a payload and a
    // DRP1 trailer and runs that payload, as it always has. The PATH `bl`
    // carries none: it is the resolving launcher, and it picks a build first.
    match try_read_trailer(&me) {
        Some(t) => {
            let sha8 = sha8_of(&t);
            if argv.first().map(String::as_str) == Some("maintenance") {
                maintenance(&argv[1..], &t, &sha8);
            }
            run_build(&me, &t, &argv)
        }
        None => resolving_main(&me, &argv),
    }
}

/// The PATH launcher: resolve which build runs here, then run it.
fn resolving_main(me: &std::path::Path, argv: &[String]) -> ! {
    let store = Store::open();
    let cwd = std::env::current_dir().unwrap_or_else(|_| std::path::PathBuf::from("/"));

    // The launcher's own verbs: they are about WHICH build runs, which only
    // the launcher knows, so no build is started to answer them.
    let verb = verb_of(argv);
    let rest: Vec<String> = verb_index(argv).map(|i| argv[i + 1..].to_vec()).unwrap_or_default();
    match verb.as_deref() {
        Some("which") => which(&store, &cwd, me),
        Some("self-update") => finish(self_update(&store, rest.first().map(String::as_str), me, &cwd).map_err(bl_err)),
        Some("self-install") => finish(self_install(me, &rest, &cwd).map_err(bl_err)),
        Some("self-gc") => finish(self_gc(&rest).map_err(bl_err)),
        Some("hooks") if rest.first().map(String::as_str) == Some("drain") => finish(drain(&store, me).map_err(bl_err)),
        Some("hooks") => finish(hooks_verb(&store, &rest, me, &cwd).map_err(bl_err)),
        _ => {}
    }

    let mut r = resolve(&store, &cwd);

    // A missing build that CAN be made is made, now: a project that pins
    // `:bl "commit:…"` must run that commit, not fail on a fresh machine.
    // `BL_BUILD=never` refuses and says what would have built it.
    if let Target::Missing { spec, .. } = &r.target {
        let buildable = matches!(parse_spec(spec), Ok(Spec::Commit(_) | Spec::BleedingEdge(_) | Spec::Channel(_) | Spec::Tag(_)));
        if buildable && std::env::var("BL_BUILD").as_deref() != Ok("never") {
            match self_update(&store, Some(spec), me, &cwd) {
                Ok(_) => r = resolve(&store, &cwd),
                Err(e) => fail(&format!("`{spec}` is not stored and could not be obtained: {e}")),
            }
        }
    }

    match r.target {
        Target::Build(id) => {
            let blob = store.blob(&id);
            let payload = store.payload(&id);
            if payload.join("bin").exists() {
                exec_payload(&payload, &id, argv)
            } else {
                // Stored sealed, not yet extracted: the blob is a drop; its own
                // trailer extracts it on first run.
                let t = try_read_trailer(&blob).unwrap_or_else(|| fail(&format!("{} is not a drop", blob.display())));
                run_build(&blob, &t, argv)
            }
        }
        Target::Drop(path) => {
            let t = try_read_trailer(&path).unwrap_or_else(|| fail(&format!("{} is not a drop", path.display())));
            run_build(&path, &t, argv)
        }
        Target::SourceMode(root) => {
            let bin = root.join("bin/bl");
            let mut cmd = Command::new(&bin);
            cmd.args(argv).env("BL_BIN", me).env_remove("BL_BUILD_ID");
            exec_or_fail(cmd, &bin)
        }
        Target::Missing { spec, hint } => {
            eprintln!("bl: no build answers `{spec}` here: {hint}");
            eprintln!("bl: `bl which` shows how this was decided");
            std::process::exit(EXIT_LAUNCHER_FAILURE)
        }
        Target::Invalid(why) => fail(&why),
    }
}

/// End a launcher verb: its message on stdout (nothing when it has none), or
/// its refusal on stderr with exit 1. A refusal is already a sentence for the
/// user, so it is printed as-is — not as a launcher failure.
fn finish(r: Result<String, String>) -> ! {
    match r {
        Ok(msg) => {
            if !msg.is_empty() {
                println!("{msg}");
            }
            std::process::exit(0)
        }
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1)
        }
    }
}

/// `bl which`: every rule the resolver consulted, and what it chose.
fn which(store: &Store, cwd: &std::path::Path, me: &std::path::Path) -> ! {
    let r = resolve(store, cwd);
    println!("launcher  {}", tildify(me));
    println!("store     {}", tildify(&store.root));
    for s in &r.steps {
        println!("  {s}");
    }
    match &r.target {
        Target::Build(id) => {
            let p = store.payload(id);
            let from = ["commit", "branch", "worktree", "built-at"]
                .iter()
                .filter_map(|k| build_info_field(&p, k).map(|v| format!("{k} {v}")))
                .collect::<Vec<_>>()
                .join(" · ");
            println!("runs      build {id}{}", if from.is_empty() { String::new() } else { format!("  ({from})") });
        }
        Target::SourceMode(root) => println!("runs      {}/bin/bl (source mode)", tildify(root)),
        Target::Drop(p) => println!("runs      the drop {}", tildify(p)),
        Target::Missing { spec, hint } => println!("runs      nothing: `{spec}`: {hint}"),
        Target::Invalid(why) => println!("runs      nothing: {why}"),
    }
    std::process::exit(0)
}

/// Run the drop `file` (whose trailer is `t`): extract its payload on first
/// use, then run it.
fn run_build(file: &std::path::Path, t: &Trailer, argv: &[String]) -> ! {
    let sha8 = sha8_of(t);
    let install = install_dir();
    let dest = install.join(&sha8);

    if !dest.join("bin").exists() {
        verify_and_extract_from(file, t, &dest, &install);
        gc_old_versions(&install, &sha8);
    }
    exec_payload(&dest, &sha8, argv)
}

/// Whether the payload at `dest` names its daemon by build. Every payload that
/// carries `BUILD_INFO.bl` does (one stat); an older one is asked by reading
/// its `vm.paths` source for `build-id`.
fn names_its_build(dest: &std::path::Path) -> bool {
    if dest.join("BUILD_INFO.bl").is_file() {
        return true;
    }
    std::fs::read_dir(dest.join("lib"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("beam_lisp-"))
        .any(|e| {
            std::fs::read_to_string(e.path().join("priv/std/vm/paths.bl"))
                .is_ok_and(|t| t.contains("(defn build-id"))
        })
}

fn exec_or_fail(mut cmd: Command, bin: &std::path::Path) -> ! {
    #[cfg(unix)]
    {
        let err = cmd.exec(); // same pid — signals pass straight through (§6.6)
        fail(&format!("exec {}: {err}", bin.display()));
    }
    #[cfg(windows)]
    {
        let status = cmd
            .status()
            .unwrap_or_else(|e| fail(&format!("spawn {}: {e}", bin.display())));
        std::process::exit(status.code().unwrap_or(EXIT_LAUNCHER_FAILURE));
    }
}

/// Run the extracted payload at `dest`, which is build `sha8`: attach to its
/// warm daemon when one serves this tree, else exec its release.
fn exec_payload(dest: &std::path::Path, sha8: &str, argv: &[String]) -> ! {
    // THIS PROCESS IS BUILD `sha8`, and everything it starts is too: the daemon
    // names its socket after it, the hello asks for it, and a VM that re-runs
    // `bl` through `BL_BIN` gets it again. Set before any thread exists. A
    // payload that predates build-named daemons gets no id, so the launcher
    // and that payload's daemon agree on the older `<tree>.sock`.
    if names_its_build(dest) {
        std::env::set_var("BL_BUILD_ID", sha8);
    } else {
        std::env::remove_var("BL_BUILD_ID");
    }
    touch_used(dest);
    let argv = argv.to_vec();

    let bin = dest.join(if cfg!(windows) { r"bin\bl.bat" } else { "bin/bl" });

    // ── daemon fast-path (unix) ──────────────────────────────────────────────
    // A warm global daemon serves the command over a socket in ~30ms instead of
    // a ~1.2s cold VM boot. Skipped only when BL_DAEMON=off and for the `bl
    // daemon` lifecycle verbs (which must reach the release). Every other verb —
    // including repl/serve/mcp/gateway and `bl watch` — runs in its own VM
    // process under the daemon (PLAN-121), so nothing is exiled to a cold VM to
    // avoid parking a serial worker: there is no serial worker.
    #[cfg(unix)]
    {
        let mode = std::env::current_dir()
            .ok()
            .as_deref()
            .and_then(resolve_root)
            .map(|r| daemon_mode(&r))
            .unwrap_or(DaemonMode::Auto);
        let off = mode == DaemonMode::Off;
        let verb = verb_of(&argv);
        let is_lifecycle = verb.as_deref() == Some("daemon");
        // PLAN-121/123: NO verb is exiled to a cold VM. A long-lived command
        // (repl, serve, mcp, gateway, lsp serve) is just a process under its
        // VM's capped env — the single serial worker it would have parked is
        // gone. Only `bl daemon` lifecycle verbs still reach the release path.

        // `bl daemon start` is a REQUEST for a daemon, not a command to run
        // inside one. Exec'd, the release parks in the foreground and dies with
        // the shell that asked for it — while the verb's own docstring (and
        // docs/bl/03) says the launcher runs it detached, which is what makes
        // `bl daemon start && bl run …` mean anything. So detach here and
        // return: the daemon outlives this process, and the caller learns
        // whether it actually came up. `BL_DAEMON=off` keeps the old
        // foreground behavior: ask for no daemon and you get none.
        if !off && daemon_start_requested(&argv) {
            let cwd = std::env::current_dir().ok();
            if let Some(root) = cwd.as_deref().and_then(resolve_root) {
                if daemon_ready(&root) {
                    println!("bl: daemon already running for this tree");
                    std::process::exit(0);
                }

                start_daemon_detached(&bin, &root);

                if wait_ready(&root) {
                    println!("bl: daemon started — commands for this tree are now warm");
                    std::process::exit(0);
                }
                eprintln!("bl: daemon did not become ready (see `bl daemon status`)");
                std::process::exit(1);
            }
        }

        if !off && !is_lifecycle {
            if let Some(code) = maybe_attach_daemon(&argv, &bin) {
                std::process::exit(code);
            }
        }
    }

    let mut cmd = Command::new(&bin);
    cmd.env("BL_BIN", self_bl());
    // Trailing args after `eval EXPR` land in System.argv() verbatim
    // (verified: bin/bl eval passes "$@" through as erl -extra). A `--`
    // would leak into argv, so it is NOT added here.
    cmd.arg("eval").arg(CLI_ENTRY).args(&argv);
    exec_or_fail(cmd, &bin)
}

// Named `gc_tests`, not `tests`: daemon.rs is `include!`d into this module and
// already owns that name.
#[cfg(test)]
mod gc_tests {
    use super::*;

    /// `maintenance meta` names the target; every name parses back to its tags.
    #[test]
    fn target_name_is_the_inverse_of_parse_target() {
        for t in ["linux/x86_64", "linux/aarch64", "macos/x86_64", "macos/aarch64", "macos/universal", "windows/x86_64"] {
            let (o, a) = parse_target(t).unwrap();
            assert_eq!(target_name(o, a), t);
        }
        assert_eq!(target_name(9, 9), "os9/arch9");
    }

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("drop-gc-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    /// The regression: a second `bl` with a DIFFERENT payload used to delete
    /// this tree, killing any VM still running from it.
    #[test]
    fn a_second_version_does_not_delete_the_first() {
        let install = scratch("coexist");
        std::fs::create_dir_all(install.join("aaaaaaaa")).unwrap();
        std::fs::create_dir_all(install.join("bbbbbbbb")).unwrap();

        gc_old_versions(&install, "bbbbbbbb");

        assert!(
            install.join("aaaaaaaa").is_dir(),
            "a recent other version must survive another version's extract"
        );
        assert!(install.join("bbbbbbbb").is_dir());
        let _ = std::fs::remove_dir_all(&install);
    }

    fn facts() -> GcFacts {
        let mut refs = std::collections::HashMap::new();
        refs.insert("pppppppp".to_string(), "channels/stable".to_string());
        GcFacts {
            in_use: "cccccccc".into(),
            refs,
            daemons: ["dddddddd".to_string()].into(),
            running: ["rrrrrrrr".to_string()].into(),
            now: std::time::SystemTime::now(),
            grace: std::time::Duration::from_secs(24 * 3_600),
            recent: std::time::Duration::from_secs(14 * 86_400),
        }
    }

    /// A build goes only when NOTHING holds it: not in use, not pointed at, no
    /// daemon, no process, and unused for longer than both windows.
    #[test]
    fn only_an_unheld_unused_build_goes() {
        let f = facts();
        let ago = |days: u64| Some(f.now - std::time::Duration::from_secs(days * 86_400));
        assert_eq!(keep_reason("cccccccc", ago(400), &f), Some(Keep::InUse));
        assert_eq!(keep_reason("pppppppp", ago(400), &f), Some(Keep::Pointed("channels/stable".into())));
        assert_eq!(keep_reason("dddddddd", ago(400), &f), Some(Keep::Daemon));
        assert_eq!(keep_reason("rrrrrrrr", ago(400), &f), Some(Keep::Running));
        assert_eq!(keep_reason("eeeeeeee", ago(3), &f), Some(Keep::Recent), "run by path, recently: kept");
        assert_eq!(keep_reason("ffffffff", None, &f), Some(Keep::Undated), "undatable: kept, never deleted");
        assert_eq!(keep_reason("aaaaaaaa", ago(20), &f), None, "nothing holds it and it is unused: it goes");
    }

    /// A deleted worktree's bleeding-edge no longer holds its build; a channel
    /// always does; the store dir itself is never a candidate.
    #[test]
    fn references_follow_live_worktrees_and_the_store_is_never_swept() {
        let install = scratch("refs");
        let store = Store { root: install.clone() };
        let live = install.join("live-wt");
        std::fs::create_dir_all(&live).unwrap();
        store.write("channels/stable", &Pointer::new("11111111")).unwrap();
        store.write("bleeding-edge/a", &Pointer::new("22222222").with("root", &live.to_string_lossy())).unwrap();
        store.write("bleeding-edge/b", &Pointer::new("33333333").with("root", "/no/such/worktree")).unwrap();
        let refs = referenced(&store);
        assert!(refs.contains_key("11111111"));
        assert!(refs.contains_key("22222222"));
        assert!(!refs.contains_key("33333333"), "a gone worktree holds nothing");

        let rows = gc_by_reference(&install, "", true);
        assert!(rows.iter().all(|r| r.name != "store"));
        assert!(install.join("store/channels/stable").exists(), "a dry run removes nothing");
        let _ = std::fs::remove_dir_all(&install);
    }

    // ── the other half of the same failure ──────────────────────────────

    /// A reboot in the middle of a first run left `<sha8>/lib` and
    /// `<sha8>/releases` but no `bin/`. The install check reads that as "version
    /// missing", so every run re-extracted and every run died on ENOTEMPTY —
    /// `bl` was dead until the directory was deleted by hand. Publishing must
    /// clear debris and take its place.
    #[test]
    fn publish_heals_a_half_extracted_version() {
        let dir = scratch("debris");
        let dest = dir.join("df3bf671");
        let tmp = dir.join("df3bf671.tmp-1234");

        // the debris: a partial tree, no bin/
        std::fs::create_dir_all(dest.join("lib")).unwrap();
        std::fs::write(dest.join("lib/partial.beam"), b"half").unwrap();
        // the finished staging tree
        std::fs::create_dir_all(tmp.join("bin")).unwrap();
        std::fs::write(tmp.join("bin/bl"), b"#!/bin/sh\n").unwrap();

        publish(&tmp, &dest).expect("debris must not be fatal");

        assert!(dest.join("bin/bl").is_file(), "the complete tree is published");
        assert!(!tmp.exists(), "the staging tree moves, not copies");
        assert!(
            !dest.join("lib/partial.beam").exists(),
            "nothing from the half-extracted tree survives"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The race the original tolerated: another process published the SAME
    /// payload while we unpacked. Losing costs our staging tree and nothing
    /// else — never the winner's tree.
    #[test]
    fn publish_concedes_a_race_to_a_complete_tree() {
        let dir = scratch("race");
        let dest = dir.join("c94bd7eb");
        let tmp = dir.join("c94bd7eb.tmp-4321");

        std::fs::create_dir_all(dest.join("bin")).unwrap();
        std::fs::write(dest.join("bin/bl"), b"winner\n").unwrap();
        std::fs::create_dir_all(tmp.join("bin")).unwrap();
        std::fs::write(tmp.join("bin/bl"), b"loser\n").unwrap();

        publish(&tmp, &dest).expect("losing the race is not failure");

        assert_eq!(
            std::fs::read(dest.join("bin/bl")).unwrap(),
            b"winner\n",
            "the published tree is left exactly as the winner wrote it"
        );
        assert!(!tmp.exists(), "the loser's staging tree is cleaned up");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
