//! `drop-launcher` — the self-extracting entry of a bundled `bl`.
//! File layout: [launcher][payload.tar.gz][trailer].
//! Runtime contract: docs/native-bundler.md §6.

#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Command;

include!("common.rs");
include!("daemon.rs");

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

/// Read ONLY the trailer (56 bytes at EOF) — cheap, O(1), on every invocation.
/// The payload sha8 (the version-dir name) comes from the trailer's stored
/// digest; the payload itself is verified once, at extraction time
/// (`verify_and_extract`), NOT re-hashed on every warm run. Re-hashing 100 MB
/// per invocation was the launcher's real latency floor (~0.3s); a warm daemon
/// attach must not pay it.
fn read_trailer_only() -> (Trailer, String) {
    use std::io::{Read, Seek, SeekFrom};
    let self_path = std::env::current_exe().unwrap_or_else(|_| fail("cannot locate myself"));
    let mut f = std::fs::File::open(&self_path)
        .unwrap_or_else(|e| fail(&format!("cannot read {}: {e}", self_path.display())));
    let flen = f.metadata().map(|m| m.len()).unwrap_or(0);
    if flen < TRAILER_LEN as u64 {
        fail("file smaller than a trailer — not a bundled bl?");
    }
    f.seek(SeekFrom::End(-(TRAILER_LEN as i64))).expect("seek trailer");
    let mut tbuf = vec![0u8; TRAILER_LEN];
    f.read_exact(&mut tbuf).expect("read trailer");
    let t = parse_trailer(&tbuf).unwrap_or_else(|| fail("no DRP1 trailer — not a bundled bl?"));
    let sha8 = hex(&t.sha256)[..8].to_string();
    (t, sha8)
}

/// Read the payload slice, VERIFY its sha256 against the trailer, and extract.
/// Only called on first run for a given sha8 (the version dir is missing).
fn verify_and_extract(t: &Trailer, dest: &std::path::Path, install: &std::path::Path) {
    use std::io::{Read, Seek, SeekFrom};
    let self_path = std::env::current_exe().expect("exe");
    let mut f = std::fs::File::open(&self_path).expect("reopen self");
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

/// Days an unused `<install>/<sha8>/` tree is kept before it is swept.
/// Override with `BL_DROP_KEEP_DAYS`.
///
/// The rule this replaces — remove every version dir except the one in use,
/// immediately — is not safe, and it fails as a CRASH, not a warning. A VM
/// execs helper binaries (`inet_gethost`, `erl_child_setup`) out of its OWN
/// erts dir, lazily, and a `bl daemon` runs from its tree for its whole life.
/// So a second `bl` with a different payload — a dev build beside a release,
/// or two releases — deleted the first one's tree from under it and the
/// running VM died with
///
///     Can not execute .../drop/<sha8>/erts-<v>/bin/inet_gethost : enoent
///
/// plus an erl_crash.dump. Re-running appeared to fix it, because the tree is
/// re-extracted: a transient-looking symptom with a permanent cause.
///
/// Age is a heuristic, not a guarantee: a tree older than the window that is
/// still in use can still be swept. 30 days makes that a deliberate,
/// documented trade instead of something any second binary can trigger.
const DEFAULT_KEEP_DAYS: u64 = 30;

fn keep_days() -> u64 {
    std::env::var("BL_DROP_KEEP_DAYS")
        .ok()
        .and_then(|v| v.trim().parse().ok())
        .unwrap_or(DEFAULT_KEEP_DAYS)
}

/// May this version dir be swept? Never the one in use, and never one we
/// cannot date — an undatable dir is kept, not deleted.
fn sweepable(
    name: &str,
    keep: &str,
    modified: Option<std::time::SystemTime>,
    cutoff: std::time::SystemTime,
) -> bool {
    name != keep && matches!(modified, Some(t) if t < cutoff)
}

/// Sweep version dirs past the retention window (docs §6, step 3), and staging
/// dirs on a much shorter one.
///
/// `<sha8>.tmp-<pid>` is what an extraction unpacks into before it publishes.
/// One that outlives its extractor means the process died mid-unpack (a reboot,
/// a `kill -9`), and it is ~100 MB of nothing. An extraction takes seconds, so a
/// day-old staging dir is debris by any measure while a live one — seconds or
/// minutes old — is never in reach.
const TMP_KEEP_HOURS: u64 = 24;

fn gc_old_versions(install: &std::path::Path, keep: &str) {
    let Some(cutoff) = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(keep_days().saturating_mul(86_400)))
    else {
        return;
    };

    let tmp_cutoff = std::time::SystemTime::now()
        .checked_sub(std::time::Duration::from_secs(TMP_KEEP_HOURS * 3_600))
        .unwrap_or(cutoff);

    if let Ok(rd) = std::fs::read_dir(install) {
        for d in rd.flatten() {
            let name = d.file_name().to_string_lossy().into_owned();

            if !d.path().is_dir() {
                continue;
            }

            let modified = d.metadata().and_then(|m| m.modified()).ok();
            let window = if name.contains(".tmp-") { tmp_cutoff } else { cutoff };

            if sweepable(&name, keep, modified, window) {
                let _ = std::fs::remove_dir_all(d.path());
            }
        }
    }
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
            println!("target: os={} arch={}", t.os, t.arch);
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

    // O(1) trailer read on every invocation; the 100 MB payload is hashed only
    // when we actually extract (first run for this version).
    let (t, sha8) = read_trailer_only();

    if argv.first().map(String::as_str) == Some("maintenance") {
        maintenance(&argv[1..], &t, &sha8);
    }

    let install = install_dir();
    let dest = install.join(&sha8);

    if !dest.join("bin").exists() {
        verify_and_extract(&t, &dest, &install);
        gc_old_versions(&install, &sha8);
    }

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

// Named `gc_tests`, not `tests`: daemon.rs is `include!`d into this module and
// already owns that name.
#[cfg(test)]
mod gc_tests {
    use super::*;

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

    /// ...and once past the window it IS swept, so the install dir cannot grow
    /// without bound.
    #[test]
    fn sweeps_only_past_the_window() {
        let now = std::time::SystemTime::now();
        let cutoff = now - std::time::Duration::from_secs(30 * 86_400);
        let ago = |days: u64| Some(now - std::time::Duration::from_secs(days * 86_400));

        assert!(sweepable("stale", "current", ago(40), cutoff));
        assert!(!sweepable("recent", "current", ago(1), cutoff));
        // the version in use is never swept, however old
        assert!(!sweepable("current", "current", ago(400), cutoff));
        // undatable → kept, never deleted
        assert!(!sweepable("undated", "current", None, cutoff));
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
