//! `drop` — assemble self-extracting `bl` binaries from a mix release.
//! docs/native-bundler.md — commands: pack | fetch | unpack | inspect.
//!
//! The ONLY packaging decision is whether OTP is bundled: the `bl` escript
//! needs a host OTP; a `drop` binary carries its own. There are no payload
//! tier flags — a drop is always the full tier (lang + datom crates + z3 +
//! explorer).

use std::fs::File;
use std::io::Write;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::exit;

include!("common.rs");

fn die(msg: &str) -> ! {
    eprintln!("drop: {msg}");
    exit(2)
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1).cloned())
}

// ── erts.lock ─────────────────────────────────────────────────────────────
// Minimal INI-ish format (docs §4):
//   otp = "29.0"
//   [linux.x86_64]
//   url = "https://…"
//   sha256 = "…"      # empty = unpinned (fetch warns)
pub struct ErtsEntry {
    pub url: String,
    pub sha256: String,
}

fn lock_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("erts.lock")
}

fn parse_lock(text: &str) -> (String, Vec<(String, ErtsEntry)>) {
    let mut otp = String::new();
    let mut entries: Vec<(String, ErtsEntry)> = Vec::new();
    let mut section = String::new();
    for line in text.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        if line.starts_with('[') && line.ends_with(']') {
            section = line[1..line.len() - 1].to_string();
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let (k, v) = (k.trim(), v.trim().trim_matches('"'));
        match (section.as_str(), k) {
            ("", "otp") => otp = v.to_string(),
            (_, "url") => entries.push((
                section.clone(),
                ErtsEntry {
                    url: v.to_string(),
                    sha256: String::new(),
                },
            )),
            (_, "sha256") => {
                if let Some(e) = entries.iter_mut().find(|(s, _)| s == &section) {
                    e.1.sha256 = v.to_string();
                }
            }
            _ => {}
        }
    }
    (otp, entries)
}

fn lock_entry<'a>(entries: &'a [(String, ErtsEntry)], target: &str) -> &'a ErtsEntry {
    let key = target.replace('/', ".");
    &entries
        .iter()
        .find(|(s, _)| s == &key)
        .unwrap_or_else(|| die(&format!("erts.lock has no [{key}] section")))
        .1
}

// ── fetch ─────────────────────────────────────────────────────────────────

fn cache_dir() -> PathBuf {
    let base = std::env::var("XDG_CACHE_HOME").unwrap_or_else(|_| {
        format!("{}/.cache", std::env::var("HOME").unwrap_or_default())
    });
    PathBuf::from(base).join("drop/erts")
}

/// Download (curl) + verify against the lock; returns cached bundle path.
fn fetch(target: &str) -> PathBuf {
    let text = std::fs::read_to_string(lock_path())
        .unwrap_or_else(|e| die(&format!("cannot read {}: {e}", lock_path().display())));
    let (otp, entries) = parse_lock(&text);
    let entry = lock_entry(&entries, target);
    let cached = cache_dir().join(format!("{target}-otp{otp}.bundle").replace('/', "_"));

    if cached.exists() {
        if !entry.sha256.is_empty() {
            let bytes = std::fs::read(&cached).unwrap_or_else(|e| die(&format!("read cache: {e}")));
            let got = sha256_hex(&bytes);
            if got != entry.sha256.to_lowercase() {
                die(&format!(
                    "cached {} sha256 {got} != pinned {} — delete the cache file",
                    cached.display(),
                    entry.sha256
                ));
            }
        }
        eprintln!("drop: erts cache hit {}", cached.display());
        return cached;
    }

    eprintln!("drop: fetching {target} erts…");
    std::fs::create_dir_all(cache_dir()).unwrap_or_else(|e| die(&format!("cache dir: {e}")));
    let status = std::process::Command::new("curl")
        .args(["-sfL", "--retry", "3", "-o"])
        .arg(&cached)
        .arg(&entry.url)
        .status()
        .unwrap_or_else(|e| die(&format!("curl spawn: {e} (is curl installed?)")));
    if !status.success() {
        die(&format!("curl failed for {target}"));
    }

    if !entry.sha256.is_empty() {
        let bytes = std::fs::read(&cached).unwrap_or_else(|e| die(&format!("read: {e}")));
        let got = sha256_hex(&bytes);
        if got != entry.sha256.to_lowercase() {
            let _ = std::fs::remove_file(&cached);
            die(&format!(
                "fetched {target} sha256 {got} != pinned {} — bundle removed",
                entry.sha256
            ));
        }
    } else {
        let bytes = std::fs::read(&cached).unwrap_or_else(|e| die(&format!("read: {e}")));
        eprintln!(
            "drop: WARNING [{}] is unpinned in erts.lock — fetched sha256 {}",
            target,
            sha256_hex(&bytes)
        );
    }
    cached
}

// ── graft ─────────────────────────────────────────────────────────────────

/// The erts dir NAME the release expects (hardcoded in releases/*/elixir).
fn release_erts_dirname(release: &Path) -> String {
    let vsn_dirs = std::fs::read_dir(release.join("releases"))
        .unwrap_or_else(|e| die(&format!("releases/: {e}")))
        .flatten()
        .filter(|d| d.path().is_dir());
    for d in vsn_dirs {
        let elixir = d.path().join("elixir");
        if let Ok(text) = std::fs::read_to_string(&elixir) {
            for line in text.lines() {
                if let Some(rest) = line.trim().strip_prefix("ERTS_BIN=") {
                    // ERTS_BIN="$SCRIPT_PATH"/../../erts-17.0.1/bin/
                    if let Some(i) = rest.find("erts-") {
                        let tail = &rest[i..];
                        let name: String = tail
                            .chars()
                            .take_while(|c| c.is_ascii_digit() || *c == '.')
                            .collect();
                        if !name.is_empty() {
                            return name;
                        }
                    }
                }
            }
        }
    }
    // fallback: whatever is currently in the release root
    release
        .read_dir()
        .unwrap_or_else(|e| die(&format!("release root: {e}")))
        .flatten()
        .map(|d| d.file_name().to_string_lossy().into_owned())
        .find(|n| n.starts_with("erts-"))
        .unwrap_or_else(|| die("no erts-* dir in release and none declared in releases/*/elixir"))
}

/// Unpack a fetched/located ERTS bundle; return its `otp_*/` root dir.
fn unpack_erts_bundle(bundle: &Path, workdir: &Path) -> PathBuf {
    let name = bundle
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    let dest = workdir.join(format!(
        "erts-unpack-{}",
        name.replace('.', "_")
    ));
    let _ = std::fs::remove_dir_all(&dest);
    std::fs::create_dir_all(&dest).unwrap_or_else(|e| die(&format!("workdir: {e}")));

    // Format by MAGIC, not filename: cached bundles are renamed.
    let mut magic = [0u8; 2];
    {
        use std::io::Read;
        let mut f = File::open(bundle)
            .unwrap_or_else(|e| die(&format!("open bundle: {e}")));
        f.read_exact(&mut magic)
            .unwrap_or_else(|e| die(&format!("read bundle magic: {e}")));
    }

    if &magic == b"MZ" {
        // Official OTP windows installer — a 7z-readable archive.
        let s = std::process::Command::new("7z")
            .arg("x")
            .arg("-y")
            .arg(format!("-o{}", dest.display())) // 7z wants -o attached
            .arg(bundle)
            .output()
            .unwrap_or_else(|e| die(&format!("7z spawn: {e} (required for windows erts)")));
        if !s.status.success() {
            die(&format!("7z failed: {}", String::from_utf8_lossy(&s.stderr)));
        }
    } else {
        let f = File::open(bundle).unwrap_or_else(|e| die(&format!("open bundle: {e}")));
        let gz = flate2::read::GzDecoder::new(f);
        let mut ar = tar::Archive::new(gz);
        ar.unpack(&dest)
            .unwrap_or_else(|e| die(&format!("bundle untar: {e}")));
    }

    // The bundle root is the single `otp_*` dir inside `dest` (or dest itself).
    let mut roots: Vec<PathBuf> = std::fs::read_dir(&dest)
        .unwrap_or_else(|e| die(&format!("bundle root: {e}")))
        .flatten()
        .map(|d| d.path())
        .filter(|p| p.is_dir())
        .collect();
    if roots.len() == 1 {
        roots.pop().unwrap()
    } else {
        dest
    }
}

/// Replace the release's erts dir with the bundle's, keeping the NAME the
/// release expects (releases/*/elixir hardcodes it).
fn graft_erts(release: &Path, bundle_root: &Path) {
    let want = release_erts_dirname(release);

    let bundle_erts = std::fs::read_dir(bundle_root)
        .unwrap_or_else(|e| die(&format!("bundle root {}: {e}", bundle_root.display())))
        .flatten()
        .map(|d| d.path())
        .find(|p| {
            p.file_name()
                .map(|n| n.to_string_lossy().starts_with("erts-"))
                .unwrap_or(false)
        })
        .unwrap_or_else(|| die("bundle contains no erts-* dir"));
    let bundle_erts_name = bundle_erts
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();

    // Remove every existing erts-* dir (the host one), then copy the bundle's
    // under the expected name — zero text patching of release scripts.
    for d in std::fs::read_dir(release)
        .unwrap_or_else(|e| die(&format!("release root: {e}")))
        .flatten()
    {
        let n = d.file_name().to_string_lossy().into_owned();
        if n.starts_with("erts-") {
            std::fs::remove_dir_all(d.path())
                .unwrap_or_else(|e| die(&format!("cannot remove old {}: {e}", n)));
        }
    }

    let dest = release.join(&want);
    copy_tree(&bundle_erts, &dest);
    instantiate_bin_srcs(&dest, &release.display().to_string(), &bundle_erts_name, &want);
    eprintln!(
        "drop: grafted {} (as {want})",
        bundle_erts.display()
    );

    // The bundle's VM is libc-specific (beam-machine linux = static musl).
    // OTP libraries ship NIFs (crypto, ssl, …) that must match that libc,
    // so wherever the bundle provides an OTP app the release also carries,
    // the bundle's copy wins. Mix deps (beam_lisp, explorer, …) are not in
    // the bundle and survive untouched. Cross-target NIFs built from Rust
    // (datom crates, explorer/polars) must themselves be built for the
    // bundle's libc — see §5 (cargo-zigbuild for musl).
    let bundle_lib = bundle_root.join("lib");
    if bundle_lib.is_dir() {
        let rel_lib = release.join("lib");
        for e in std::fs::read_dir(&bundle_lib)
            .unwrap_or_else(|e| die(&format!("bundle lib: {e}")))
            .flatten()
        {
            let name = e.file_name().to_string_lossy().into_owned();
            let target_dir = rel_lib.join(&name);
            if target_dir.exists() {
                std::fs::remove_dir_all(&target_dir)
                    .unwrap_or_else(|e| die(&format!("cannot replace {name}: {e}")));
                copy_tree(&e.path(), &target_dir);
                eprintln!("drop: otp lib {name} from bundle (libc-matched)");
            }
        }
    }
}

/// Instantiate the bundle's `*.src` bin scripts (erl.src → erl, …).
///
/// Modern OTP erl scripts are relocatable — `find_rootdir` walks up from
/// `$0` — but they are SHIPPED as templates: `%FINAL_ROOTDIR%` is the
/// fallback root and the bundle's own erts dir name is baked into
/// `$ROOTDIR/erts-X.Y/bin`. Substitute the release root as fallback and
/// rewrite the erts name to the one the release scripts expect.
fn instantiate_bin_srcs(erts_dir: &Path, release_root: &str, bundle_name: &str, want_name: &str) {
    let bin = erts_dir.join("bin");
    let rd = match std::fs::read_dir(&bin) {
        Ok(rd) => rd,
        Err(e) => die(&format!("erts bin: {e}")),
    };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Some(stem) = name.strip_suffix(".src") else {
            continue;
        };
        let text = std::fs::read_to_string(e.path())
            .unwrap_or_else(|err| die(&format!("read {}: {err}", e.path().display())));
        let text = text
            .replace("%FINAL_ROOTDIR%", release_root)
            .replace(bundle_name, want_name);
        let out = bin.join(stem);
        std::fs::write(&out, &text)
            .unwrap_or_else(|err| die(&format!("write {}: {err}", out.display())));
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o755));
        }
    }
}

/// Recursive copy preserving exec permission bits (erl/beam.smp must stay +x).
fn copy_tree(src: &Path, dest: &Path) {
    std::fs::create_dir_all(dest)
        .unwrap_or_else(|e| die(&format!("mkdir {}: {e}", dest.display())));
    for e in std::fs::read_dir(src)
        .unwrap_or_else(|e| die(&format!("read {}: {e}", src.display())))
        .flatten()
    {
        let from = e.path();
        let to = dest.join(e.file_name());
        if from.is_dir() {
            copy_tree(&from, &to);
        } else {
            std::fs::copy(&from, &to)
                .unwrap_or_else(|err| die(&format!("copy {}: {err}", from.display())));
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                if let Ok(m) = e.metadata() {
                    let mode = m.permissions().mode();
                    if mode & 0o111 != 0 {
                        let _ =
                            std::fs::set_permissions(&to, std::fs::Permissions::from_mode(0o755));
                    }
                }
            }
        }
    }
}

/// Assert at least one native object in the release matches the TARGET os
/// (ELF / Mach-O / PE magic). Catches "packed a linux payload for windows".
fn assert_native_matches(release: &Path, os: u8) {
    let want_magic: &[&[u8]] = match os {
        OS_WINDOWS => &[b"MZ"],
        OS_DARWIN => &[&[0xcf, 0xfa, 0xed, 0xfe], &[0xca, 0xfe, 0xba, 0xbe]],
        _ => &[b"\x7fELF"],
    };
    fn scan(dir: &Path, want: &[&[u8]]) -> bool {
        let mut found = false;
        if let Ok(rd) = std::fs::read_dir(dir) {
            for e in rd.flatten() {
                let p = e.path();
                if p.is_dir() {
                    if scan(&p, want) {
                        found = true;
                        break;
                    }
                } else if let Some(ext) = p.extension().map(|x| x.to_string_lossy().into_owned()) {
                    if matches!(ext.as_str(), "so" | "dll") {
                        if let Ok(mut f) = File::open(&p) {
                            let mut head = [0u8; 4];
                            if f.read_exact(&mut head).is_ok()
                                && want.iter().any(|m| head.starts_with(m))
                            {
                                found = true;
                                break;
                            }
                        }
                    }
                }
            }
        }
        found
    }
    let native = release.join("lib");
    if !scan(&native, want_magic) {
        die(&format!(
            "release payload has no native objects matching target os={os} — wrong release for this target?"
        ));
    }
}

// ── deterministic tar.gz ──────────────────────────────────────────────────

fn tar_gz_dir(src: &Path) -> Vec<u8> {
    let mut files: Vec<PathBuf> = Vec::new();
    fn walk(dir: &Path, out: &mut Vec<PathBuf>) {
        let mut rd: Vec<_> = std::fs::read_dir(dir)
            .unwrap_or_else(|e| die(&format!("cannot read {}: {e}", dir.display())))
            .flatten()
            .map(|d| d.path())
            .collect();
        rd.sort();
        for p in rd {
            if p.is_dir() {
                walk(&p, out);
            } else {
                out.push(p);
            }
        }
    }
    walk(src, &mut files);

    let gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    let mut b = tar::Builder::new(gz);

    for p in &files {
        let rel = p
            .strip_prefix(src)
            .unwrap_or_else(|e| die(&format!("prefix walk error: {e}")))
            .to_path_buf();
        let mut f =
            File::open(p).unwrap_or_else(|e| die(&format!("cannot open {}: {e}", p.display())));
        let meta = f
            .metadata()
            .unwrap_or_else(|e| die(&format!("stat {}: {e}", p.display())));
        let mut header = tar::Header::new_gnu();
        header.set_size(meta.len());
        header.set_mode(0o755);
        header.set_mtime(0);
        header.set_uid(0);
        header.set_gid(0);
        header.set_username("").ok();
        header.set_groupname("").ok();
        header.set_cksum();
        b.append_data(&mut header, &rel, &mut f)
            .unwrap_or_else(|e| die(&format!("tar append {}: {e}", rel.display())));
    }

    b.into_inner()
        .unwrap_or_else(|e| die(&format!("tar finish: {e}")))
        .finish()
        .unwrap_or_else(|e| die(&format!("gzip finish: {e}")))
}

// ── commands ──────────────────────────────────────────────────────────────

fn cmd_pack(args: &[String]) {
    let release = PathBuf::from(
        arg_value(args, "--release").unwrap_or_else(|| die("pack requires --release DIR")),
    );
    let out =
        PathBuf::from(arg_value(args, "--out").unwrap_or_else(|| die("pack requires --out BIN")));
    let launcher = arg_value(args, "--launcher")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::current_exe()
                .ok()
                .and_then(|e| e.ancestors().nth(1).map(|d| d.to_path_buf()))
                .map(|d| d.join("drop-launcher"))
                .unwrap_or_else(|| die("cannot locate drop-launcher; pass --launcher"))
        });
    let target = arg_value(args, "--target");
    let erts_arg = arg_value(args, "--erts"); // "auto" | bundle path

    if !release.join("bin").exists() || !release.join("lib").exists() {
        die(&format!(
            "{} does not look like a mix release (no bin/ + lib/)",
            release.display()
        ));
    }

    // Work on a COPY so the host release is never mutated by grafting.
    let tmp_root = std::env::temp_dir().join(format!("drop-pack-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp_root);
    copy_tree(&release, &tmp_root);

    let (os, _arch) = match &target {
        Some(t) => parse_target(t)
            .unwrap_or_else(|| die("bad --target (os/arch: linux/x86_64, macos/aarch64, windows/x64…)")),
        None => (host_os(), host_arch()),
    };

    // ERTS: the ONLY packaging decision is bundled-or-not; a drop always
    // bundles. Source: explicit bundle, the lock (auto / cross-target), or
    // the release's own erts dir (host build, no --target).
    let work = tmp_root.with_extension("erts-work");
    if let Some(erts) = &erts_arg {
        if erts == "auto" {
            let t_name =
                target.clone().unwrap_or_else(|| die("--erts auto requires --target"));
            let bundle = fetch(&t_name);
            graft_erts(&tmp_root, &unpack_erts_bundle(&bundle, &work));
        } else {
            graft_erts(&tmp_root, &unpack_erts_bundle(&PathBuf::from(erts), &work));
        }
    } else if target.is_some() {
        let bundle = fetch(target.clone().unwrap().as_str());
        graft_erts(&tmp_root, &unpack_erts_bundle(&bundle, &work));
    } // else: host target, release's own erts dir rides as-is.

    assert_native_matches(&tmp_root, os);

    eprintln!("drop: tar.gz {}", tmp_root.display());
    let payload = tar_gz_dir(&tmp_root);
    let _ = std::fs::remove_dir_all(&tmp_root);
    let _ = std::fs::remove_dir_all(&work);
    let sha_full = sha256_hex(&payload);
    let mut sha_arr = [0u8; 32];
    use sha2::{Digest, Sha256};
    sha_arr.copy_from_slice(&Sha256::digest(&payload));

    let mut launcher_bytes = Vec::new();
    File::open(&launcher)
        .and_then(|mut f| f.read_to_end(&mut launcher_bytes))
        .unwrap_or_else(|e| die(&format!("cannot read launcher {}: {e}", launcher.display())));

    let offset = launcher_bytes.len() as u64;
    let len = payload.len() as u64;
    let mut out_bytes = launcher_bytes;
    out_bytes.extend_from_slice(&payload);
    out_bytes.extend_from_slice(&encode_trailer(offset, len, &sha_arr, os, host_arch()));

    File::create(&out)
        .and_then(|mut f| f.write_all(&out_bytes))
        .unwrap_or_else(|e| die(&format!("cannot write {}: {e}", out.display())));

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&out, std::fs::Permissions::from_mode(0o755));
    }

    eprintln!(
        "drop: wrote {} — launcher {:.1} MB + payload {:.1} MB (gz), sha256 {}…",
        out.display(),
        offset as f64 / 1048576.0,
        len as f64 / 1048576.0,
        &sha_full[..12]
    );
}

fn host_os() -> u8 {
    if cfg!(target_os = "macos") {
        OS_DARWIN
    } else if cfg!(target_os = "windows") {
        OS_WINDOWS
    } else {
        OS_LINUX
    }
}

fn host_arch() -> u8 {
    if cfg!(target_arch = "aarch64") {
        ARCH_AARCH64
    } else {
        ARCH_X86_64
    }
}

fn cmd_fetch(args: &[String]) {
    let target = arg_value(args, "--target")
        .unwrap_or_else(|| die("fetch requires --target os/arch"));
    let path = fetch(&target);
    println!("{}", path.display());
}

fn cmd_unpack(args: &[String]) {
    let bin = arg_value(args, "--bin")
        .or_else(|| args.first().cloned())
        .unwrap_or_else(|| die("unpack requires a bundle path"));
    let dir =
        PathBuf::from(arg_value(args, "--dir").unwrap_or_else(|| die("unpack requires --dir DIR")));
    let data = std::fs::read(&bin).unwrap_or_else(|e| die(&format!("cannot read {bin}: {e}")));
    let t = parse_trailer(&data).unwrap_or_else(|| die(&format!("{bin} has no DRP1 trailer")));
    let payload = &data[t.offset as usize..(t.offset + t.len) as usize];
    extract_tar_gz(payload, &dir).unwrap_or_else(|e| die(&format!("unpack failed: {e}")));
    println!("unpacked {bin} → {}", dir.display());
}

fn cmd_inspect(path: Option<&str>) -> ! {
    let path = path.unwrap_or_else(|| die("inspect requires a bundle path"));
    let data = std::fs::read(path).unwrap_or_else(|e| die(&format!("cannot read {path}: {e}")));
    match parse_trailer(&data) {
        Some(t) => {
            println!("format:      DRP{FORMAT_VERSION}");
            println!(
                "payload:     offset={} len={} ({:.1} MB)",
                t.offset,
                t.len,
                t.len as f64 / 1048576.0
            );
            println!("sha256:      {}", hex(&t.sha256));
            println!("target:      os={} arch={}", t.os, t.arch);
            println!("total:       {} bytes", data.len());
            std::process::exit(0)
        }
        None => die(&format!("{path} has no DRP1 trailer")),
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("pack") => cmd_pack(&args[1..]),
        Some("fetch") => cmd_fetch(&args[1..]),
        Some("unpack") => cmd_unpack(&args[1..]),
        Some("inspect") => cmd_inspect(args.get(1).map(String::as_str)),
        Some(other) => die(&format!(
            "unknown command {other} (pack | fetch | unpack | inspect)"
        )),
        None => die("usage: drop pack --release DIR --out BIN [--target os/arch] [--erts auto|FILE] [--launcher BIN]"),
    }
}
