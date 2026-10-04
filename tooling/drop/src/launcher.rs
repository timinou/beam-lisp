//! `drop-launcher` — the self-extracting entry of a bundled `bl`.
//! File layout: [launcher][payload.tar.gz][trailer].
//! Runtime contract: docs/native-bundler.md §6.

#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Command;

include!("common.rs");
include!("daemon.rs");
include!("store.rs");
include!("transport.rs");
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
    const VALUED: [&str; 12] = [
        "-p",
        "--path",
        "--code-path",
        "-o",
        "--out",
        "--tier",
        "--jobs",
        "--port",
        ROOT_FLAG,
        LOG_FLAG,
        IDLE_FLAG,
        LINES_FLAG,
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

// The start-spelling recognition lives in transport.rs (`start_requested`),
// beside the `LIFECYCLE_VERBS` it belongs with.

// ── tests: the daemon fast-path's verb detection ────────────────────────────
#[cfg(test)]
mod verb_tests {
    use super::verb_of;

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
        assert_eq!(v(&["--root", "/x", "run", "f"]).as_deref(), Some("run"), "--root takes a value");
        assert_eq!(v(&["", "lint"]).as_deref(), Some("lint"));
    }

    #[test]
    fn empty_and_flags_only_have_no_verb() {
        assert_eq!(v(&[]), None);
        assert_eq!(v(&["--json"]), None);
        assert_eq!(v(&["-p"]), None);
        assert_eq!(v(&["--"]), None);
    }

    /// The log/idle/lines flags take a VALUE: a value that looks like a verb must
    /// not become the verb.
    #[test]
    fn the_new_global_flags_are_skipped_by_verb_index() {
        let a = |args: &[&str]| args.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(super::verb_index(&a(&["--log", "x", "realm", "start"])), Some(2));
        assert_eq!(super::verb_index(&a(&["--idle", "30", "run", "f"])), Some(2));
        assert_eq!(super::verb_index(&a(&["--lines", "50", "run", "f"])), Some(2));
        assert_eq!(v(&["--log", "x", "realm", "start"]).as_deref(), Some("realm"));
    }
    // `bl realm start` is the invocation the launcher answers ITSELF; that
    // recognition is `start_requested` in transport.rs, tested by
    // `transport_tests::realm_start_is_a_start_request`.
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

/// Seconds per hour and per day — the units the windows above are stated in,
/// named once so no magic number drifts.
const SECS_PER_HOUR: u64 = 3_600;
const SECS_PER_DAY: u64 = 86_400;

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
    for &dir in POINTER_DIRS {
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

/// Build ids a live daemon serves, from a runtime-dir socket name.
fn daemon_builds() -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    let Some(dir) = runtime_dir() else { return out };
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            if let Some(b) = build_from_sock(&e.file_name().to_string_lossy()) {
                out.insert(b.to_string());
            }
        }
    }
    out
}

/// The build a daemon socket names: the segment after the LAST '-' before
/// `.sock`. Generic over both `<endpoint-key>-<build>` names — a tree id and
/// the shared `warm` key both carry no '-' — so `warm-3ffa4c3a.sock` names
/// `3ffa4c3a` exactly as `<tree-id>-3ffa4c3a.sock` does. `None` for a legacy
/// `<tree-id>.sock` (no build) or a non-socket file.
fn build_from_sock(name: &str) -> Option<&str> {
    name.strip_suffix(".sock")?.rsplit_once('-').map(|(_, build)| build)
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
        .is_some_and(|age| age < std::time::Duration::from_secs(SECS_PER_HOUR));
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
        grace: std::time::Duration::from_secs(hours_env("BL_DROP_GRACE_HOURS", DEFAULT_GRACE_HOURS) * SECS_PER_HOUR),
        recent: std::time::Duration::from_secs(hours_env("BL_DROP_KEEP_DAYS", DEFAULT_RECENT_DAYS) * SECS_PER_DAY),
    };
    let tmp_window = std::time::Duration::from_secs(TMP_KEEP_HOURS * SECS_PER_HOUR);

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

/// Try the warm VM: attach when one answers for this tree, and — only under
/// `Transport::Start` — start one (detached) and retry once. `Some(exit_code)`
/// when the command was served (or lost after send — unknown outcome, exit 1);
/// `None` to fall back to a cold `bin/bl` boot.

/// `bl` is THIS executable — the launcher. The release's own `bin/bl` is a
/// different program with a different command surface (`start`, `daemon`,
/// `eval`, `rpc`), and its path changes with every rebuild. So anything that
/// has to re-invoke `bl` from inside a running one — a gateway detaching
/// itself, a systemd unit's ExecStart — is handed this path as `BL_BIN`,
/// instead of looking up `bl` on a PATH where, inside a drop, the first match
/// can be the release script itself.
///
/// The failure it prevents, seen for real: `bl vm start gateway` in an installed
/// drop detached `setsid <payload>/bin/bl vm start gateway --foreground`, and the release script
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
            eprintln!("bl: warm VM connection lost mid-command; outcome unknown");
            Some(1)
        }
        Attach::Stalled(secs) => {
            eprintln!(
                "bl: the warm VM has sent nothing — not even its heartbeat — for {secs}s, so it \
                 is unresponsive. The command may still be running there, and it is NOT re-run \
                 here (outcome unknown). Run `bl vm` to see it, or `bl vm stop` to end it."
            );
            Some(1)
        }
        _ => None,
    }
}

fn maybe_attach_daemon(argv: &[String], bin: &std::path::Path, t: Transport, shared: bool) -> Option<i32> {
    let cwd = std::env::current_dir().ok()?;
    let root = tree_root(&cwd, argv)?;

    match try_attach(&root, argv, shared) {
        Attach::Exit(code) => Some(code),
        a @ (Attach::LostAfterSend | Attach::Stalled(_)) => after_attach(a),
        Attach::RestartRequired => {
            // the daemon is stale (checkout changed). Stop it, restart, retry once.
            // Say so: a daemon that vanishes without a word looks like a command
            // that failed for no reason, and the next command pays a cold boot.
            eprintln!(
                "bl: the warm VM for this tree was started from a different build; \
                 stopping it and running this command cold"
            );
            stop_daemon(bin, &root);
            retry_from_warm(bin, &root, argv, t, shared)
        }
        Attach::Fallback => retry_from_warm(bin, &root, argv, t, shared),
    }
}

/// When the transport permits Start, kick off a warm VM and return `None` so
/// the caller runs THIS command cold, right now. The start is NEVER awaited: a
/// boot the command did not ask to wait for must not delay it, and a start that
/// fails costs it nothing. Only the first starter acts — `claim_start` keeps a
/// second from spawning a duplicate VM for the same endpoint.
#[cfg(unix)]
fn retry_from_warm(bin: &std::path::Path, root: &std::path::Path, _argv: &[String], t: Transport, shared: bool) -> Option<i32> {
    if t != Transport::Start {
        return None;
    }
    if let Some(ep) = endpoints(root, shared) {
        if claim_start(&ep.starting, now_secs(), START_GRACE_SECS) {
            start_daemon_detached(bin, root, &build_id(), shared);
        }
    }
    None
}

/// Stop the warm VM for `root` by asking the release, which owns the lifecycle.
#[cfg(unix)]
fn stop_daemon(bin: &std::path::Path, root: &std::path::Path) {
    let mut cmd = release_command(bin);
    cmd.args(warm_stop_argv(root));
    let _ = cmd.status();
}

/// A release invocation: `bin/bl eval <CLI_ENTRY> <argv…>`. Trailing args land
/// in `System.argv()` verbatim — the one handoff both `exec_payload` and the
/// lifecycle helpers use, so the entry expression is spelled once.
fn release_command(bin: &std::path::Path) -> Command {
    let mut cmd = Command::new(bin);
    cmd.arg("eval").arg(CLI_ENTRY).env("BL_BIN", self_bl());
    cmd
}

/// Poll for an authenticated-reachable daemon, up to a startup deadline.
#[cfg(unix)]
fn wait_ready(root: &std::path::Path, shared: bool) -> bool {
    for _ in 0..600 {
        // 600 * 200ms = 120s
        if daemon_ready(root, shared) {
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
            let bin = root.join(LAUNCHER_REL);
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
    if dest.join(BUILD_INFO_FILE).is_file() {
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

/// What a payload can do is read from its own `vm` sources, the way
/// `names_its_build` reads an older one: the launcher outlives the payloads it runs.
const VM_SOURCE_DIR: &str = "priv/std/vm";
/// The rule a payload carries when its VM can serve many projects. An older payload
/// binds per-tree sockets only, so a project that asks to share must be given its own
/// VM there: the shared socket name would be one nobody binds.
const SHARED_VM_MARKER: &str = "(defn shared?";
/// The file a payload carries when its warm VM leaves by itself after idling. A VM
/// started from a payload without it would live until someone stopped it.
const IDLE_EXIT_FILE: &str = "idle.bl";

/// The text of `priv/std/vm/<file>` in the payload at `dest`, if it has one.
fn payload_vm_source(dest: &std::path::Path, file: &str) -> Option<String> {
    std::fs::read_dir(dest.join("lib"))
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().starts_with("beam_lisp-"))
        .find_map(|e| std::fs::read_to_string(e.path().join(VM_SOURCE_DIR).join(file)).ok())
}

/// Whether the payload at `dest` can host a shared VM.
fn supports_shared_vm(dest: &std::path::Path) -> bool {
    payload_vm_source(dest, "paths.bl").is_some_and(|t| t.contains(SHARED_VM_MARKER))
}

/// Whether the payload at `dest` can be started in the background without leaving a
/// VM that never ends.
fn supports_background_start(dest: &std::path::Path) -> bool {
    payload_vm_source(dest, IDLE_EXIT_FILE).is_some()
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

    let bin = dest.join(if cfg!(windows) { r"bin\bl.bat" } else { LAUNCHER_REL });

    // ── warm-VM fast path (unix) ────────────────────────────────────────────
    // A warm VM serves the command over a socket in ~30ms instead of a ~1.2s
    // cold boot. The transport is DECLARED — `--cold` / `--warm`, the tree's
    // `env.bl :warm`, the config, then DEFAULT_TRANSPORT — never read from the
    // environment. Cold skips both this path and the start handoff; lifecycle
    // verbs (`realm`, `vm`) never attach, because they talk to the VM
    // themselves. Every other verb — including repl/serve/mcp and
    // `bl watch` — runs in its own VM process under the warm one (PLAN-121), so
    // nothing is exiled to a cold VM to avoid parking a serial worker: there is
    // no serial worker.
    #[cfg(unix)]
    {
        let cwd = std::env::current_dir().ok();
        let root = cwd.as_deref().and_then(|c| tree_root(c, &argv));
        // Read the project's env.bl ONCE: `--share-vm`/`--own-vm` or the `:vm`
        // declaration decides the endpoint for this whole invocation (the default
        // is own). The declaration is read from the nearest env.bl at or above
        // where the command ran (an explicit --root names that directory instead),
        // not from the engine-checkout root: a command typed in a subdirectory of
        // a shared project must still see `:vm "shared"`.
        let declared_at = match root_override(&argv) {
            Some(r) => Some(r),
            None => cwd.as_deref().and_then(project_dir),
        };
        let env_bl = declared_at.and_then(|d| std::fs::read_to_string(d.join(PROJECT_FILE)).ok());
        let shared = shared_for(&argv, env_bl.as_deref()) && supports_shared_vm(dest);
        // Whether the project shares its VM decides the DEFAULT transport (an own
        // VM attaches, a shared one starts); anything the user declared still wins.
        let t = effective_transport(
            root.as_deref().map(|r| transport(r, &argv, shared)).unwrap_or_else(|| default_transport(shared)),
            supports_background_start(dest),
        );
        let is_lifecycle = verb_of(&argv).as_deref().is_some_and(|v| LIFECYCLE_VERBS.contains(&v));
        // `bl realm start` is a REQUEST for a warm VM, not a command to run
        // inside one. Exec'd, the release parks in the foreground and dies with
        // the shell that asked for it — so detach here and return: the VM
        // outlives this process, and the caller learns whether it actually came
        // up.
        if t != Transport::Cold {
            if start_requested(&argv) {
                if let Some(root) = root.as_deref() {
                    if daemon_ready(root, shared) {
                        println!("bl: a warm VM is already running for this tree");
                        std::process::exit(0);
                    }

                    // The explicit request goes through the SAME start as the
                    // automatic one, so it lands in the same log; it claims the
                    // marker too, so a start already in flight is WAITED for,
                    // not duplicated. This is the one caller that does wait:
                    // the user asked for a warm VM and is owed the outcome.
                    let log = log_path(root, &build_id(), shared);
                    let claimed = endpoints(root, shared)
                        .is_some_and(|e| claim_start(&e.starting, now_secs(), START_GRACE_SECS));
                    if claimed {
                        start_daemon_detached(&bin, root, &build_id(), shared);
                    }

                    if wait_ready(root, shared) {
                        println!("bl: warm VM started — commands for this tree are now warm");
                        std::process::exit(0);
                    }
                    match log {
                        Some(p) => {
                            eprintln!("bl: the warm VM did not become ready — its log: {}", p.display());
                            eprintln!("bl: read it with `bl vm logs` once the VM is listed (`bl vm`).");
                        }
                        None => eprintln!(
                            "bl: the warm VM did not become ready (no log path; set XDG_STATE_HOME or HOME)"
                        ),
                    }
                    std::process::exit(1);
                }
            }
            if !is_lifecycle {
                if let Some(code) = maybe_attach_daemon(&argv, &bin, t, shared) {
                    std::process::exit(code);
                }
            }
        }
    }

    // Trailing args after `eval EXPR` land in System.argv() verbatim
    // (verified: bin/bl eval passes "$@" through as erl -extra). A `--`
    // would leak into argv, so it is NOT added here.
    let mut cmd = release_command(&bin);
    cmd.args(&argv);
    exec_or_fail(cmd, &bin)
}

// Named `gc_tests`, not `tests`: daemon.rs is `include!`d into this module and
// already owns that name.
#[cfg(test)]
mod gc_tests {
    use super::*;

    fn payload_with_paths(tag: &str, paths_bl: &str) -> std::path::PathBuf {
        let d = std::env::temp_dir().join(format!("drop-shared-probe-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let dir = d.join("lib/beam_lisp-0.1.0/priv/std/vm");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("paths.bl"), paths_bl).unwrap();
        d
    }

    #[test]
    fn only_a_payload_whose_vm_idles_out_can_be_started_in_the_background() {
        let with = payload_with_paths("idle-yes", "(defn build-id [] \"x\")\n");
        std::fs::write(with.join("lib/beam_lisp-0.1.0/priv/std/vm/idle.bl"), "(ns vm.idle)\n").unwrap();
        let without = payload_with_paths("idle-no", "(defn build-id [] \"x\")\n");
        assert!(supports_background_start(&with));
        assert!(!supports_background_start(&without), "no idle.bl: it would never end");
        let _ = std::fs::remove_dir_all(&with);
        let _ = std::fs::remove_dir_all(&without);
    }

    #[test]
    fn a_payload_that_can_host_a_shared_vm_says_so_in_its_paths() {
        let new = payload_with_paths("new", "(defn shared? [root build] false)\n");
        let old = payload_with_paths("old", "(defn build-id [] \"src\")\n");
        assert!(supports_shared_vm(&new));
        assert!(!supports_shared_vm(&old), "an older payload binds per-tree sockets only");
        assert!(!supports_shared_vm(&std::env::temp_dir().join("drop-no-such-payload")));
        let _ = std::fs::remove_dir_all(&new);
        let _ = std::fs::remove_dir_all(&old);
    }

    /// `maintenance meta` names the target; every name parses back to its tags.
    #[test]
    fn target_name_is_the_inverse_of_parse_target() {
        for t in ["linux/x86_64", "linux/aarch64", "macos/x86_64", "macos/aarch64", "macos/universal", "windows/x86_64"] {
            let (o, a) = parse_target(t).unwrap();
            assert_eq!(target_name(o, a), t);
        }
        assert_eq!(target_name(9, 9), "os9/arch9");
    }

    /// A daemon socket names its build after the LAST '-', so both the shared
    /// `warm-<build>` and the per-checkout `<tree-id>-<build>` names parse.
    #[test]
    fn a_socket_names_its_build_after_the_last_dash() {
        assert_eq!(build_from_sock("warm-3ffa4c3a.sock"), Some("3ffa4c3a"));
        assert_eq!(build_from_sock("57461829a20cc2af-3ffa4c3a.sock"), Some("3ffa4c3a"));
        assert_eq!(build_from_sock("57461829a20cc2af.sock"), None, "a legacy tree socket names no build");
        assert_eq!(build_from_sock("warm-3ffa4c3a.token"), None);
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
            grace: std::time::Duration::from_secs(24 * SECS_PER_HOUR),
            recent: std::time::Duration::from_secs(14 * SECS_PER_DAY),
        }
    }

    /// A build goes only when NOTHING holds it: not in use, not pointed at, no
    /// daemon, no process, and unused for longer than both windows.
    #[test]
    fn only_an_unheld_unused_build_goes() {
        let f = facts();
        let ago = |days: u64| Some(f.now - std::time::Duration::from_secs(days * SECS_PER_DAY));
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
        store.write(&store.channel_key("stable"), &Pointer::new("11111111")).unwrap();
        store.write(&store.bleeding_edge_key("a"), &Pointer::new("22222222").with("root", &live.to_string_lossy())).unwrap();
        store.write(&store.bleeding_edge_key("b"), &Pointer::new("33333333").with("root", "/no/such/worktree")).unwrap();
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
        std::fs::write(tmp.join(LAUNCHER_REL), b"#!/bin/sh\n").unwrap();

        publish(&tmp, &dest).expect("debris must not be fatal");

        assert!(dest.join(LAUNCHER_REL).is_file(), "the complete tree is published");
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
        std::fs::write(dest.join(LAUNCHER_REL), b"winner\n").unwrap();
        std::fs::create_dir_all(tmp.join("bin")).unwrap();
        std::fs::write(tmp.join(LAUNCHER_REL), b"loser\n").unwrap();

        publish(&tmp, &dest).expect("losing the race is not failure");

        assert_eq!(
            std::fs::read(dest.join(LAUNCHER_REL)).unwrap(),
            b"winner\n",
            "the published tree is left exactly as the winner wrote it"
        );
        assert!(!tmp.exists(), "the loser's staging tree is cleaned up");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
