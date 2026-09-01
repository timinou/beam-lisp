//! `drop-launcher` — the self-extracting entry of a bundled `bl`.
//! File layout: [launcher][payload.tar.gz][trailer].
//! Runtime contract: docs/native-bundler.md §6.

#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::process::Command;

include!("common.rs");

const EXIT_LAUNCHER_FAILURE: i32 = 126;

fn fail(msg: &str) -> ! {
    eprintln!("drop: {msg}");
    std::process::exit(EXIT_LAUNCHER_FAILURE)
}

/// Read our own binary, parse + verify the trailer and the payload hash.
fn read_self() -> (Trailer, String) {
    let self_path = std::env::current_exe().unwrap_or_else(|_| fail("cannot locate myself"));
    let data = std::fs::read(&self_path)
        .unwrap_or_else(|e| fail(&format!("cannot read {}: {e}", self_path.display())));
    let t = parse_trailer(&data).unwrap_or_else(|| fail("no DRP1 trailer — not a bundled bl?"));
    let end = t.offset as usize + t.len as usize;
    if end + TRAILER_LEN > data.len() {
        fail("trailer offsets overrun the file — truncated bundle?");
    }
    let want = hex(&t.sha256);
    let got = sha256_hex(&data[t.offset as usize..end]);
    if got != want {
        fail(&format!(
            "payload corrupt (sha256 {got} != {want}) — re-download"
        ));
    }
    (t, got[..8].to_string())
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

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();

    let (t, sha8) = read_self();

    if argv.first().map(String::as_str) == Some("maintenance") {
        maintenance(&argv[1..], &t, &sha8);
    }

    let install = install_dir();
    let dest = install.join(&sha8);

    if !dest.join("bin").exists() {
        let self_path = std::env::current_exe().expect("exe");
        let mut f = std::fs::File::open(&self_path).expect("reopen self");
        use std::io::{Read, Seek, SeekFrom};
        f.seek(SeekFrom::Start(t.offset)).expect("seek");
        let mut payload = vec![0u8; t.len as usize];
        f.read_exact(&mut payload).expect("read payload");
        std::fs::create_dir_all(&install)
            .unwrap_or_else(|e| fail(&format!("cannot create install dir {}: {e}", install.display())));
        extract_tar_gz(&payload, &dest)
            .unwrap_or_else(|e| fail(&format!("first-run extraction failed: {e}")));
    }

    gc_old_versions(&install, &sha8);

    let bin = dest.join(if cfg!(windows) { r"bin\bl.bat" } else { "bin/bl" });
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
