//! `drop-launcher` — the self-extracting entry of a bundled `bl`.
//! File layout: [launcher][payload.tar.gz][trailer].
//! Runtime contract: docs/native-bundler.md §6.

#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Command;

include!("common.rs");
include!("daemon.rs");

const EXIT_LAUNCHER_FAILURE: i32 = 126;

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

/// Remove every version dir except `keep` (docs §6.3).
fn gc_old_versions(install: &std::path::Path, keep: &str) {
    if let Ok(rd) = std::fs::read_dir(install) {
        for d in rd.flatten() {
            let name = d.file_name().to_string_lossy().into_owned();
            if name != keep && d.path().is_dir() {
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
#[cfg(unix)]
fn maybe_attach_daemon(argv: &[String], bin: &std::path::Path) -> Option<i32> {
    let cwd = std::env::current_dir().ok()?;
    let root = resolve_root(&cwd)?;

    match try_attach(&root, argv) {
        Attach::Exit(code) => Some(code),
        Attach::LostAfterSend => {
            eprintln!("bl: daemon connection lost mid-command; outcome unknown");
            Some(1)
        }
        Attach::RestartRequired => {
            // the daemon is stale (checkout changed). Stop it, restart, retry once.
            let _ = std::process::Command::new(bin)
                .arg("eval")
                .arg("BeamLisp.Ns.Bl.Cli.main([\"daemon\",\"stop\"])")
                .env("BL_DAEMON_ROOT", &root)
                .status();
            if autostart_enabled() {
                start_daemon_detached(bin, &root);
                if wait_ready(&root) {
                    return match try_attach(&root, argv) {
                        Attach::Exit(code) => Some(code),
                        Attach::LostAfterSend => Some(1),
                        _ => None,
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
                        Attach::LostAfterSend => Some(1),
                        _ => None,
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
        if let Some(ep) = endpoints(root) {
            if ep.sock.exists() {
                // a quick attach probe: connect + hello only
                if matches!(try_attach(root, &["version".to_string()]), Attach::Exit(_)) {
                    return true;
                }
            }
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
    // A warm `bl daemon` for the caller's tree serves the command over a socket
    // in ~30ms instead of a ~1.2s cold VM boot. Skipped when BL_DAEMON=off, and
    // for the daemon lifecycle verbs themselves (which must reach the release).
    #[cfg(unix)]
    {
        let off = std::env::var("BL_DAEMON").map(|v| v == "off").unwrap_or(false);
        let is_lifecycle = argv.first().map(String::as_str) == Some("daemon");
        if !off && !is_lifecycle {
            if let Some(code) = maybe_attach_daemon(&argv, &bin) {
                std::process::exit(code);
            }
        }
    }

    let mut cmd = Command::new(&bin);
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
