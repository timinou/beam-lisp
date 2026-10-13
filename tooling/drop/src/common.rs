// Shared format + payload handling between `drop pack` and `drop-launcher`.
// Trailer layout is the contract — docs/native-bundler.md §2.1.
// (included via include! — no //! inner docs allowed here)

pub const MAGIC: &[u8; 4] = b"DRP1";
pub const FORMAT_VERSION: u16 = 1;
/// offset u64 + len u64 + sha256 32B + os u8 + arch u8 + version u16 + magic 4B
pub const TRAILER_LEN: usize = 8 + 8 + 32 + 1 + 1 + 2 + 4;

/// Eval-mode entry handed to the release's `bin/bl eval`.
/// Trailing args land in System.argv() verbatim (a `--` would leak into argv —
/// verified empirically). The CLI entry starts the supervised application using
/// the native launcher's shared policy; eval-mode releases start no apps for it.
pub const CLI_ENTRY: &str = "BeamLisp.Launcher.start_app!(System.argv(), %{})";

/// The layout names shared by the launcher, the packer, and the store. One
/// spelling each, so a rename cannot drift between the two that read them.
#[allow(dead_code)] // pack.rs includes this file but does not use them all
pub const PROJECT_FILE: &str = "env.bl";
/// The release entry script, relative to a payload or payload tree.
#[allow(dead_code)]
pub const LAUNCHER_REL: &str = "bin/bl";
/// A file every beam-lisp tree root has; the launcher walks up to find it.
#[allow(dead_code)]
pub const TREE_MARKER: &str = "priv/boot/core.bl";
/// A payload's printed build facts; the launcher reads one field from it.
#[allow(dead_code)]
pub const BUILD_INFO_FILE: &str = "BUILD_INFO.bl";

pub const OS_LINUX: u8 = 0;
pub const OS_DARWIN: u8 = 1;
pub const OS_WINDOWS: u8 = 2;
pub const ARCH_X86_64: u8 = 0;
pub const ARCH_AARCH64: u8 = 1;
pub const ARCH_UNIVERSAL: u8 = 2;

pub struct Trailer {
    pub offset: u64,
    pub len: u64,
    pub sha256: [u8; 32],
    pub os: u8,
    pub arch: u8,
}

/// "linux/x86_64" etc → (os tag, arch tag).
pub fn parse_target(s: &str) -> Option<(u8, u8)> {
    let (os, arch) = s.split_once('/')?;
    let o = match os {
        "linux" => OS_LINUX,
        "macos" => OS_DARWIN,
        "windows" => OS_WINDOWS,
        _ => return None,
    };
    let a = match arch {
        "x86_64" | "x64" => ARCH_X86_64,
        "aarch64" => ARCH_AARCH64,
        // macOS bundles are dual-arch universal; the tag rides the trailer
        // as its own arch value.
        "universal" if o == OS_DARWIN => ARCH_UNIVERSAL,
        _ => return None,
    };
    Some((o, a))
}

/// (os tag, arch tag) → "linux/x86_64" etc., the inverse of `parse_target`.
/// An unknown tag is shown as its number, never guessed.
#[allow(dead_code)]
pub fn target_name(os: u8, arch: u8) -> String {
    let o = match os {
        OS_LINUX => "linux".to_string(),
        OS_DARWIN => "macos".to_string(),
        OS_WINDOWS => "windows".to_string(),
        n => format!("os{n}"),
    };
    let a = match arch {
        ARCH_X86_64 => "x86_64".to_string(),
        ARCH_AARCH64 => "aarch64".to_string(),
        ARCH_UNIVERSAL => "universal".to_string(),
        n => format!("arch{n}"),
    };
    format!("{o}/{a}")
}

pub fn parse_trailer(data: &[u8]) -> Option<Trailer> {
    if data.len() < TRAILER_LEN {
        return None;
    }
    let t = &data[data.len() - TRAILER_LEN..];
    if &t[52..56] != MAGIC {
        return None;
    }
    let version = u16::from_le_bytes([t[50], t[51]]);
    if version != FORMAT_VERSION {
        return None;
    }
    let mut sha = [0u8; 32];
    sha.copy_from_slice(&t[16..48]);
    Some(Trailer {
        offset: u64::from_le_bytes(t[0..8].try_into().ok()?),
        len: u64::from_le_bytes(t[8..16].try_into().ok()?),
        sha256: sha,
        os: t[48],
        arch: t[49],
    })
}

pub fn encode_trailer(offset: u64, len: u64, sha256: &[u8; 32], os: u8, arch: u8) -> Vec<u8> {
    let mut v = Vec::with_capacity(TRAILER_LEN);
    v.extend_from_slice(&offset.to_le_bytes());
    v.extend_from_slice(&len.to_le_bytes());
    v.extend_from_slice(sha256);
    v.push(os);
    v.push(arch);
    v.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    v.extend_from_slice(MAGIC);
    v
}

pub fn sha256_hex(bytes: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    let d = Sha256::digest(bytes);
    hex(&d)
}

/// Raw sha256 digest bytes (the daemon tree fingerprint).
#[allow(dead_code)]
pub fn sha256_bytes(bytes: &[u8]) -> Vec<u8> {
    use sha2::{Digest, Sha256};
    Sha256::digest(bytes).to_vec()
}

/// Hex-encode raw bytes (no hashing) — for displaying a stored digest.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// First-install location (docs/native-bundler.md §6.2).
/// A service can keep reproducible drop storage separate from its durable XDG data.
/// DROP_STORE_ROOT names the store itself (no implicit /drop suffix).
fn explicit_store_root(value: &std::ffi::OsStr) -> Result<std::path::PathBuf, &'static str> {
    let path = std::path::PathBuf::from(value);
    let raw = value.to_string_lossy();
    if raw.split(['/', '\\']).any(|part| part == ".") || !path.is_absolute() || path.components().any(|c| matches!(c, std::path::Component::ParentDir | std::path::Component::CurDir)) {
        return Err("DROP_STORE_ROOT must be an absolute path without . or .. components");
    }
    if path.parent().is_none() {
        return Err("DROP_STORE_ROOT must not be a filesystem root");
    }
    Ok(path)
}

pub fn install_dir() -> std::path::PathBuf {
    if let Some(value) = std::env::var_os("DROP_STORE_ROOT") {
        return explicit_store_root(&value).unwrap_or_else(|message| {
            eprintln!("drop: {message}");
            std::process::exit(2)
        });
    }
    if cfg!(target_os = "windows") {
        if let Ok(l) = std::env::var("LOCALAPPDATA") {
            return std::path::PathBuf::from(l).join("drop");
        }
        return std::path::PathBuf::from(r"C:\Program Files\drop");
    }
    if cfg!(target_os = "macos") {
        if let Ok(h) = std::env::var("HOME") {
            return std::path::PathBuf::from(h).join("Library/Application Support/drop");
        }
    } else if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() {
            return std::path::PathBuf::from(x).join("drop");
        }
    }
    if let Ok(h) = std::env::var("HOME") {
        return std::path::PathBuf::from(h).join(".local/share/drop");
    }
    std::path::PathBuf::from("/tmp/drop")
}

/// Zip-slip guard: reject absolute paths and `..` components.
pub fn safe_path(base: &std::path::Path, rel: &std::path::Path) -> std::io::Result<std::path::PathBuf> {
    if rel.is_absolute() {
        return Err(std::io::Error::other(format!(
            "payload contains absolute path: {}",
            rel.display()
        )));
    }
    let mut out = base.to_path_buf();
    for c in rel.components() {
        match c {
            std::path::Component::Normal(p) => out.push(p),
            std::path::Component::CurDir => {}
            _ => {
                return Err(std::io::Error::other(format!(
                    "payload contains unsafe path component: {}",
                    rel.display()
                )))
            }
        }
    }
    Ok(out)
}

/// Atomic tar.gz extraction into `dest` (a per-process `.tmp-<pid>` sibling,
/// then rename). Shared by the launcher (first-run install) and `drop unpack`
/// (CI), so both tolerate a concurrent extractor of the same payload.
pub fn extract_tar_gz(payload: &[u8], dest: &std::path::Path) -> std::io::Result<()> {
    // Stage under a name only THIS process owns. Two `bl` invocations extract
    // the same version more easily than it looks — an editor opening two
    // workspaces, `bl realm start` beside a `bl run`, two jobs on one
    // machine — and a SHARED staging path makes them delete each other's work
    // mid-unpack (observed: "failed to unpack … into <dir>.tmp/…", and
    // "Directory not empty" when the loser's rename met the winner's tree).
    let tmp = dest.with_extension(format!("tmp-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp)?;

    match unpack_into(payload, &tmp).and_then(|()| publish(&tmp, dest)) {
        Ok(()) => Ok(()),
        Err(e) => {
            let _ = std::fs::remove_dir_all(&tmp);
            Err(e)
        }
    }
}

/// Unpack the payload into an existing, empty staging dir.
fn unpack_into(payload: &[u8], tmp: &std::path::Path) -> std::io::Result<()> {
    let gz = flate2::read::GzDecoder::new(payload);
    let mut ar = tar::Archive::new(gz);
    ar.set_preserve_permissions(true);
    for e in ar.entries()? {
        let mut e = e?;
        let rel = e.path()?.into_owned();
        let out = safe_path(tmp, &rel)?;
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        e.unpack(&out)?;
    }
    make_entry_executable(tmp, LAUNCHER_REL);
    Ok(())
}

/// Publish a finished staging tree as `dest`.
///
/// Losing the race is not an error: another process extracted the SAME payload
/// — same sha256, verified before unpacking — so the tree already in place is
/// the tree we were about to publish. What must not happen is publishing over
/// it, or reporting failure for a `bl` that is ready to run.
///
/// A tree at `dest` with no `bin/` is the other case, and it used to be
/// permanent: the install check is `dest/bin`, so a half-extracted tree reads
/// as "version missing", every later run re-extracts, and every later run dies
/// on the same `ENOTEMPTY` — `bl` unusable until a human deletes the directory
/// (observed after a reboot landed in the middle of a first run). Such a tree
/// holds nothing that can be running, so it is cleared and replaced.
fn publish(tmp: &std::path::Path, dest: &std::path::Path) -> std::io::Result<()> {
    match std::fs::rename(tmp, dest) {
        Ok(()) => Ok(()),
        Err(_) => {
            if dest.join("bin").exists() {
                let _ = std::fs::remove_dir_all(tmp);
                Ok(())
            } else {
                // Debris: an extraction a reboot or a kill cut in half. The
                // install check (`dest/bin`) still reads the version as
                // missing, so every later run re-extracts and loses this same
                // rename with ENOTEMPTY — `bl` stays dead until someone clears
                // the tree by hand. Nothing runs out of a tree with no `bin/`.
                if dest.is_dir() {
                    let _ = std::fs::remove_dir_all(dest);
                } else {
                    let _ = std::fs::remove_file(dest);
                }

                match std::fs::rename(tmp, dest) {
                    Ok(()) => Ok(()),
                    Err(second) => {
                        let _ = std::fs::remove_dir_all(tmp);
                        // A sibling may have published a complete tree meanwhile.
                        if dest.join("bin").exists() {
                            Ok(())
                        } else {
                            Err(second)
                        }
                    }
                }
            }
        }
    }
}

#[cfg(unix)]
pub fn make_entry_executable(dir: &std::path::Path, rel: &str) {
    use std::os::unix::fs::PermissionsExt;
    let p = dir.join(rel);
    if p.is_file() {
        if let Ok(meta) = std::fs::metadata(&p) {
            let mut perms = meta.permissions();
            perms.set_mode(perms.mode() | 0o755);
            let _ = std::fs::set_permissions(&p, perms);
        }
    }
}
#[cfg(not(unix))]
pub fn make_entry_executable(_dir: &std::path::Path, _rel: &str) {}

#[cfg(test)]
mod store_root_tests {
    use super::explicit_store_root;
    #[test]
    fn explicit_store_is_independent_of_xdg_and_has_no_added_suffix() {
        assert_eq!(explicit_store_root(std::ffi::OsStr::new("/var/cache/app-runtime")).unwrap(), std::path::PathBuf::from("/var/cache/app-runtime"));
    }
    #[test]
    fn explicit_store_rejects_relative_empty_root_and_parent_traversal() {
        for path in ["", "relative", "/", "/var/cache/../data", "/var/./cache"] {
            assert!(explicit_store_root(std::ffi::OsStr::new(path)).is_err(), "{path}");
        }
    }
}
