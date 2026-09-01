// Shared format + payload handling between `drop pack` and `drop-launcher`.
// Trailer layout is the contract — docs/native-bundler.md §2.1.
// (included via include! — no //! inner docs allowed here)

pub const MAGIC: &[u8; 4] = b"DRP1";
pub const FORMAT_VERSION: u16 = 1;
/// offset u64 + len u64 + sha256 32B + os u8 + arch u8 + version u16 + magic 4B
pub const TRAILER_LEN: usize = 8 + 8 + 32 + 1 + 1 + 2 + 4;

/// Eval-mode entry handed to the release's `bin/bl eval`.
/// Trailing args land in System.argv() verbatim (a `--` would leak into argv —
/// verified empirically); AOT.boot/0 starts the substrate on demand, so
/// "apps not started" in eval mode is irrelevant.
pub const CLI_ENTRY: &str = "BeamLisp.Ns.Bl.Cli.main(System.argv())";

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

/// Hex-encode raw bytes (no hashing) — for displaying a stored digest.
pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// First-install location (docs/native-bundler.md §6.2).
pub fn install_dir() -> std::path::PathBuf {
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

/// Atomic tar.gz extraction into `dest` (`.tmp` sibling, then rename).
/// Shared by the launcher (first-run install) and `drop unpack` (CI).
pub fn extract_tar_gz(payload: &[u8], dest: &std::path::Path) -> std::io::Result<()> {
    let tmp = dest.with_extension("tmp");
    let _ = std::fs::remove_dir_all(&tmp);
    std::fs::create_dir_all(&tmp)?;

    let gz = flate2::read::GzDecoder::new(payload);
    let mut ar = tar::Archive::new(gz);
    ar.set_preserve_permissions(true);
    for e in ar.entries()? {
        let mut e = e?;
        let rel = e.path()?.into_owned();
        let out = safe_path(&tmp, &rel)?;
        if let Some(parent) = out.parent() {
            std::fs::create_dir_all(parent)?;
        }
        e.unpack(&out)?;
    }
    make_entry_executable(&tmp, "bin/bl");
    std::fs::rename(&tmp, dest)?;
    Ok(())
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
