// builder.rs — getting a build into the store: fetch a release, or build a tree.
// (included via include! into launcher.rs — no //! inner docs allowed here)
//
//   self_update(store, spec, me)  the verb `bl self-update [SPEC]`
//   build_tree(store, tree, me)   seal a source tree with `bin/bl self-build`
//   fetch_release(store, tag)     download + verify a GitHub release asset
//
// Nothing here is on the hot path: it runs when a build is missing, from a
// hook, or by hand. It may run git and curl; the resolver may not.
//
// ONE BUILD AT A TIME on the machine (`BuildLock`): a build holds ~1.3 GB per
// compiler process on a host already under memory pressure, and `self-build`
// stages into one fixed directory.

use std::process::Stdio;

/// The GitHub repository releases come from (`:repo` in the config).
pub fn release_repo() -> String {
    config_literal("repo").unwrap_or_else(|| "timinou/beam-lisp".to_string())
}

/// This platform's release asset name, as `.github/workflows/release.yml`
/// names them.
pub fn asset_name() -> Option<&'static str> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some("bl-linux-x86_64"),
        ("linux", "aarch64") => Some("bl-linux-aarch64"),
        ("macos", "aarch64") => Some("bl-macos-arm64"),
        ("macos", "x86_64") => Some("bl-macos-x86_64"),
        _ => None,
    }
}

fn cache_dir() -> PathBuf {
    std::env::var("XDG_CACHE_HOME")
        .ok()
        .filter(|x| !x.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| expand_home("~/.cache"))
        .join("bl")
}

fn say(msg: &str) {
    eprintln!("bl: {msg}");
}

/// Every failure a verb returns starts with `bl: `, once.
fn bl_err(msg: String) -> String {
    if msg.starts_with("bl:") { msg } else { format!("bl: {msg}") }
}

// ── the machine-wide build lock ─────────────────────────────────────────────

pub struct BuildLock {
    path: PathBuf,
}

impl BuildLock {
    /// Take the lock, waiting for a live holder; a holder whose process is gone
    /// is stale and replaced.
    pub fn take(store: &Store) -> BuildLock {
        let path = store.meta().join("locks").join("build");
        let _ = std::fs::create_dir_all(path.parent().unwrap());
        let mut told = false;
        loop {
            match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut f) => {
                    use std::io::Write;
                    let _ = write!(f, "{}", std::process::id());
                    return BuildLock { path };
                }
                Err(_) => {
                    let holder = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse::<u32>().ok());
                    match holder {
                        Some(pid) if Path::new(&format!("/proc/{pid}")).exists() || !Path::new("/proc").exists() => {
                            if !told {
                                say(&format!("another build is running (pid {pid}); waiting for it"));
                                told = true;
                            }
                            std::thread::sleep(std::time::Duration::from_secs(2));
                        }
                        _ => {
                            let _ = std::fs::remove_file(&path);
                        }
                    }
                }
            }
        }
    }
}

impl Drop for BuildLock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

// ── running things ──────────────────────────────────────────────────────────

/// Minutes one build step may run before it is killed (`BL_BUILD_TIMEOUT_MIN`).
/// A self-build compiles every tier, so a namespace that DOES something at load
/// (a server's `(run)` at top level) parks it forever; measured: a step that
/// normally takes ~6 minutes sat serving an MCP endpoint instead.
const DEFAULT_BUILD_TIMEOUT_MIN: u64 = 45;

/// Run `cmd`, appending its output to `log`. Ok on exit 0; else the last lines
/// of the log, so a failure names its own cause. A step past its deadline is
/// killed (with its process group) and reported as such.
fn run_logged(mut cmd: Command, log: &Path, what: &str) -> Result<(), String> {
    use std::io::Write;
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log)
        .map_err(|e| format!("cannot open log {}: {e}", log.display()))?;
    let _ = writeln!(f, "\n=== {what}");
    let out = f.try_clone().map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let mut child = cmd
        .stdin(Stdio::null())
        .stdout(Stdio::from(out))
        .stderr(Stdio::from(f))
        .spawn()
        .map_err(|e| format!("{what}: could not start: {e}"))?;
    let limit = std::time::Duration::from_secs(60 * hours_env("BL_BUILD_TIMEOUT_MIN", DEFAULT_BUILD_TIMEOUT_MIN));
    let started = std::time::Instant::now();
    let status = loop {
        match child.try_wait().map_err(|e| e.to_string())? {
            Some(s) => break s,
            None if started.elapsed() > limit => {
                #[cfg(unix)]
                {
                    let _ = Command::new("kill").args(["-9", &format!("-{}", child.id())]).status();
                }
                let _ = child.kill();
                let _ = child.wait();
                return Err(format!(
                    "{what} ran past {} minutes and was stopped (BL_BUILD_TIMEOUT_MIN); log {}",
                    limit.as_secs() / 60,
                    log.display()
                ));
            }
            None => std::thread::sleep(std::time::Duration::from_millis(500)),
        }
    };
    if status.success() {
        Ok(())
    } else {
        let text = std::fs::read_to_string(log).unwrap_or_default();
        let tail: Vec<&str> = text.lines().rev().take(15).collect();
        let tail: Vec<&str> = tail.into_iter().rev().collect();
        Err(format!("{what} failed ({status}); log {}:\n{}", log.display(), tail.join("\n")))
    }
}

fn git_out(dir: &Path, args: &[&str]) -> Option<String> {
    let o = Command::new("git").arg("-C").arg(dir).args(args).stderr(Stdio::null()).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// The main worktree of the repository `tree` belongs to (the parent of the
/// common git dir).
pub fn main_worktree(tree: &Path) -> Option<PathBuf> {
    let common = git_out(tree, &["rev-parse", "--path-format=absolute", "--git-common-dir"])?;
    let p = PathBuf::from(common);
    (p.file_name()? == ".git").then(|| p.parent().map(Path::to_path_buf)).flatten()
}

/// Copy the gitignored PINNED assets a build needs (`priv/z3`, `priv/embed`)
/// from `from` into `tree` when `tree` has none: downloaded artefacts, the same
/// bytes for every commit. Reflinked where the filesystem can.
///
/// `priv/native` is NOT one of them: those `.so` files are built from
/// `native/*` of the commit being built, and a copy is the checkout's crate
/// source, not this commit's (measured: a `latest` seeded from a checkout with
/// an edited `datom_fjall` crate shipped that crate's NIF and died at load with
/// `:nif_not_loaded`). `build_natives` compiles them from the tree instead.
fn seed_assets(from: &Path, tree: &Path, log: &Path) -> Result<(), String> {
    if from == tree {
        return Ok(());
    }
    for rel in ["priv/z3", "priv/embed"] {
        let (src, dst) = (from.join(rel), tree.join(rel));
        let empty = std::fs::read_dir(&dst).map(|mut d| d.next().is_none()).unwrap_or(true);
        if src.is_dir() && empty {
            let _ = std::fs::create_dir_all(&dst);
            let mut cmd = Command::new("cp");
            cmd.arg("-a").arg("--reflink=auto").arg(format!("{}/.", src.display())).arg(&dst);
            run_logged(cmd, log, &format!("seed {rel} from {}", tildify(from)))?;
        }
    }
    Ok(())
}

/// Build every `native/<crate>` of `tree` with cargo and install its cdylib as
/// `priv/native/<crate>.so` (`.dylib` on macOS is loaded under the same `.so`
/// name, as `vm.native` installs it). The boot itself loads `lazy_memo`, so
/// this runs before the tree's own `bin/bl` does anything. Cargo's shared
/// target directory makes a crate that did not change a no-op.
fn build_natives(tree: &Path, log: &Path) -> Result<(), String> {
    let native = tree.join("native");
    let dest = tree.join("priv/native");
    std::fs::create_dir_all(&dest).map_err(|e| e.to_string())?;
    let Ok(rd) = std::fs::read_dir(&native) else { return Ok(()) };
    let mut crates: Vec<PathBuf> = rd.flatten().map(|e| e.path()).filter(|p| p.join("Cargo.toml").is_file()).collect();
    crates.sort();
    for dir in crates {
        let name = dir.file_name().unwrap().to_string_lossy().into_owned();
        let mut cmd = Command::new("cargo");
        cmd.args(["build", "--release", "--message-format=short", "--manifest-path"]).arg(dir.join("Cargo.toml"));
        run_logged(cmd, log, &format!("cargo build native/{name}"))?;
        let out = cargo_target_dir(&dir).join("release");
        let lib = [format!("lib{name}.so"), format!("lib{name}.dylib")]
            .into_iter()
            .map(|f| out.join(f))
            .find(|p| p.is_file())
            .ok_or_else(|| format!("native/{name}: cargo produced no cdylib in {}", out.display()))?;
        let tmp = dest.join(format!("{name}.so.tmp-{}", std::process::id()));
        std::fs::copy(&lib, &tmp).map_err(|e| e.to_string())?;
        std::fs::rename(&tmp, dest.join(format!("{name}.so"))).map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// Where cargo writes for the crate at `dir`: `cargo metadata`'s answer, which
/// honours `CARGO_TARGET_DIR` and any `build.target-dir` config.
fn cargo_target_dir(dir: &Path) -> PathBuf {
    Command::new("cargo")
        .args(["metadata", "--format-version", "1", "--no-deps", "--manifest-path"])
        .arg(dir.join("Cargo.toml"))
        .stderr(Stdio::null())
        .output()
        .ok()
        .and_then(|o| json_string(&String::from_utf8_lossy(&o.stdout), "target_directory"))
        .map(PathBuf::from)
        .unwrap_or_else(|| dir.join("target"))
}

fn tree_bl(tree: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new(tree.join("bin/bl"));
    cmd.args(args)
        .current_dir(tree)
        .env("BL_DAEMON", "off")
        .env_remove("BL_BUILD_ID")
        .env_remove("BL_USE")
        .env_remove("BL_DAEMON_ROOT");
    cmd
}

// ── building a tree ─────────────────────────────────────────────────────────

pub struct Built {
    pub id: String,
    pub key: Option<String>,
    pub commit: Option<String>,
}

/// Build the source tree at `tree` into the store, sealed with `launcher` (a
/// payload-less launcher: the PATH `bl` itself), and record it as the tree's
/// bleeding-edge and under its source key. `extra` are more pointers to move to
/// it (`channels/latest`).
pub fn build_tree(store: &Store, tree: &Path, launcher: &Path, extra: &[&str]) -> Result<Built, String> {
    let _lock = BuildLock::take(store);
    let before = stamp(tree);

    // The lock was waited for: another build may have produced exactly this.
    if let Some(p) = store.read(&format!("bleeding-edge/{}", tree_id(tree))) {
        if p.get("stamp") == Some(before.as_str()) && store.has(&p.build) {
            for rel in extra {
                store.write(rel, &p).map_err(|e| e.to_string())?;
            }
            say(&format!("{} is already built as {}", tildify(tree), p.build));
            return Ok(Built { id: p.build.clone(), key: p.get("key").map(str::to_string), commit: p.get("commit").map(str::to_string) });
        }
    }

    let logs = store.meta().join("logs");
    std::fs::create_dir_all(&logs).map_err(|e| e.to_string())?;
    let log = logs.join(format!("{}.log", tree_id(tree)));
    let _ = std::fs::write(&log, "");
    say(&format!("building {} (several minutes; log {})", tildify(tree), tildify(&log)));

    if let Some(main) = main_worktree(tree) {
        seed_assets(&main, tree, &log)?;
    }
    let incoming = store.meta().join("incoming");
    std::fs::create_dir_all(&incoming).map_err(|e| e.to_string())?;
    let out = incoming.join(format!("build-{}.drop", std::process::id()));
    let scratch = cache_dir().join("scratch");

    build_natives(tree, &log)?;
    run_logged(tree_bl(tree, &["deps", "fetch"]), &log, "bl deps fetch")?;
    run_logged(tree_bl(tree, &["deps", "compile"]), &log, "bl deps compile")?;
    let seal = tree_bl(
        tree,
        &[
            "self-build",
            "--bin",
            &launcher.to_string_lossy(),
            "--out",
            &out.to_string_lossy(),
            "--scratch",
            &scratch.to_string_lossy(),
        ],
    );
    run_logged(seal, &log, "bl self-build")?;

    let id = publish_drop(store, &out)?;
    let after = stamp(tree);
    let payload = store.payload(&id);
    let key = build_info_field(&payload, "source-key");
    let commit = build_info_field(&payload, "commit");

    let mut p = Pointer::new(&id)
        .with("root", &tree.to_string_lossy())
        .with("branch", &head_branch(tree).unwrap_or_default())
        .with("commit", commit.as_deref().unwrap_or(""))
        .with("key", key.as_deref().unwrap_or(""));
    if before == after {
        p = p.with("stamp", &before);
    } else {
        say("the tree changed while it was building; this build is kept, and the tree runs from source until it is built again");
    }
    store.write(&format!("bleeding-edge/{}", tree_id(tree)), &p).map_err(|e| e.to_string())?;
    if let Some(k) = &key {
        store.write(&format!("sources/{k}"), &p).map_err(|e| e.to_string())?;
    }
    for rel in extra {
        store.write(rel, &p).map_err(|e| e.to_string())?;
    }
    say(&format!("built {} → {id}", tildify(tree)));
    Ok(Built { id, key, commit })
}

/// Verify and extract the sealed drop at `file` into the store, then remove the
/// file. Returns its build id.
pub fn publish_drop(store: &Store, file: &Path) -> Result<String, String> {
    let t = try_read_trailer(file).ok_or_else(|| format!("{} is not a drop", file.display()))?;
    let id = sha8_of(&t);
    if !store.payload(&id).join("bin").exists() {
        extract_checked(file, &t, &store.payload(&id))?;
    }
    let _ = std::fs::remove_file(file);
    Ok(id)
}

fn extract_checked(file: &Path, t: &Trailer, dest: &Path) -> Result<(), String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(file).map_err(|e| e.to_string())?;
    f.seek(SeekFrom::Start(t.offset)).map_err(|e| e.to_string())?;
    let mut payload = vec![0u8; t.len as usize];
    f.read_exact(&mut payload).map_err(|e| e.to_string())?;
    let got = sha256_hex(&payload);
    let want = hex(&t.sha256);
    if got != want {
        return Err(format!("{}: payload digest {got} does not match its trailer {want}", file.display()));
    }
    extract_tar_gz(&payload, dest).map_err(|e| format!("extracting {}: {e}", file.display()))
}

/// Build commit `sha` of the repository at `source` in a detached worktree
/// under the cache (reused for the same commit).
pub fn build_commit(store: &Store, source: &Path, sha: &str, launcher: &Path, extra: &[&str]) -> Result<Built, String> {
    let full = git_out(source, &["rev-parse", "--verify", &format!("{sha}^{{commit}}")])
        .ok_or_else(|| format!("{} has no commit {sha} (fetch it first)", tildify(source)))?;
    let tree = cache_dir().join("build-trees").join(&full[..12]);
    if !tree.join(".git").exists() {
        let _ = std::fs::create_dir_all(tree.parent().unwrap());
        let mut cmd = Command::new("git");
        cmd.arg("-C").arg(source).args(["worktree", "add", "--detach", "--force"]).arg(&tree).arg(&full);
        let log = cache_dir().join("worktree-add.log");
        let _ = std::fs::create_dir_all(cache_dir());
        run_logged(cmd, &log, &format!("git worktree add {}", &full[..12]))?;
    }
    let tree = std::fs::canonicalize(&tree).unwrap_or(tree);
    build_tree(store, &tree, launcher, extra)
}

// ── releases ────────────────────────────────────────────────────────────────

fn curl_text(url: &str) -> Result<String, String> {
    let o = Command::new("curl")
        .args(["-fsSL", "--retry", "2", "-H", "Accept: application/vnd.github+json", url])
        .stdin(Stdio::null())
        .output()
        .map_err(|e| format!("curl could not start: {e}"))?;
    if o.status.success() {
        Ok(String::from_utf8_lossy(&o.stdout).into_owned())
    } else {
        Err(format!("GET {url}: {}", String::from_utf8_lossy(&o.stderr).trim()))
    }
}

/// The value of the first `"key": "value"` in a JSON text (a scan: the
/// launcher carries no JSON parser, and these are flat string fields).
pub fn json_string(text: &str, key: &str) -> Option<String> {
    let needle = format!("\"{key}\"");
    let at = text.find(&needle)? + needle.len();
    let rest = text[at..].trim_start().strip_prefix(':')?.trim_start().strip_prefix('"')?;
    Some(rest[..rest.find('"')?].to_string())
}

/// Download release `tag` (None = the newest non-prerelease) for this platform,
/// verify it against its published `.sha256`, extract it, and record it under
/// `tags/<tag>`. Returns (tag, build id). An asset already stored with the same
/// digest is not downloaded again.
pub fn fetch_release(store: &Store, tag: Option<&str>) -> Result<(String, String), String> {
    let repo = release_repo();
    let asset = asset_name().ok_or("no release asset is published for this platform")?;
    let api = match tag {
        None => format!("https://api.github.com/repos/{repo}/releases/latest"),
        Some(t) => format!("https://api.github.com/repos/{repo}/releases/tags/{t}"),
    };
    let json = curl_text(&api)?;
    let tag = json_string(&json, "tag_name").ok_or_else(|| format!("{api}: no tag_name in the answer"))?;
    let base = format!("https://github.com/{repo}/releases/download/{tag}");
    let sums = curl_text(&format!("{base}/{asset}.sha256"))?;
    let want = sums.split_whitespace().next().unwrap_or("").to_ascii_lowercase();
    if want.len() != 64 {
        return Err(format!("{base}/{asset}.sha256 does not hold a sha256"));
    }

    if let Some(p) = store.read(&format!("tags/{tag}")) {
        if p.get("asset-sha256") == Some(want.as_str()) && store.has(&p.build) {
            return Ok((tag, p.build));
        }
    }

    let incoming = store.meta().join("incoming");
    std::fs::create_dir_all(&incoming).map_err(|e| e.to_string())?;
    let file = incoming.join(format!("{asset}-{tag}.{}", std::process::id()));
    say(&format!("downloading {repo} {tag} ({asset})"));
    let st = Command::new("curl")
        .args(["-fL", "--retry", "2", "--progress-bar", "-o"])
        .arg(&file)
        .arg(format!("{base}/{asset}"))
        .stdin(Stdio::null())
        .status()
        .map_err(|e| format!("curl could not start: {e}"))?;
    if !st.success() {
        let _ = std::fs::remove_file(&file);
        return Err(format!("downloading {base}/{asset} failed ({st})"));
    }
    let got = std::fs::read(&file).map(|b| sha256_hex(&b)).map_err(|e| e.to_string())?;
    if got != want {
        let _ = std::fs::remove_file(&file);
        return Err(format!("{asset} {tag}: sha256 {got} does not match the published {want}"));
    }
    let id = publish_drop(store, &file)?;
    let p = Pointer::new(&id).with("tag", &tag).with("asset-sha256", &want);
    store.write(&format!("tags/{tag}"), &p).map_err(|e| e.to_string())?;
    say(&format!("{tag} → {id}"));
    Ok((tag, id))
}

// ── the verb ────────────────────────────────────────────────────────────────

/// The beam-lisp checkout builds come from: the config's `:source`, else the
/// main worktree of the source tree `cwd` is in.
pub fn source_for(cwd: &Path) -> Option<PathBuf> {
    source_repo().or_else(|| source_tree(cwd).and_then(|t| main_worktree(&t)))
}

/// `bl self-update [SPEC]`: put SPEC's build in the store (and move its
/// channel). With no SPEC: `stable`, then `latest`.
pub fn self_update(store: &Store, spec: Option<&str>, me: &Path, cwd: &Path) -> Result<String, String> {
    let Some(spec) = spec else {
        let s = self_update(store, Some("stable"), me, cwd)?;
        let l = self_update(store, Some("latest"), me, cwd).unwrap_or_else(|e| format!("latest: {e}"));
        return Ok(format!("stable {s}; latest {l}"));
    };
    match parse_spec(spec)? {
        Spec::Channel(c) if c == "stable" => {
            let (tag, id) = fetch_release(store, None)?;
            store.write("channels/stable", &Pointer::new(&id).with("tag", &tag)).map_err(|e| e.to_string())?;
            Ok(format!("{id} ({tag})"))
        }
        Spec::Channel(_) => match source_repo() {
            // A machine with the source checkout: `latest` is ITS main, built here.
            Some(src) => {
                let b = build_commit(store, &src, "main", me, &["channels/latest"])?;
                Ok(format!("{} (main {})", b.id, b.commit.as_deref().map(|c| &c[..8.min(c.len())]).unwrap_or("?")))
            }
            // Without one: the rolling `latest` pre-release CI publishes from main.
            None => {
                let (_, id) = fetch_release(store, Some("latest"))?;
                store.write("channels/latest", &Pointer::new(&id).with("tag", "latest")).map_err(|e| e.to_string())?;
                Ok(id)
            }
        },
        Spec::Tag(t) => fetch_release(store, Some(&t)).map(|(_, id)| id),
        Spec::Commit(c) => {
            let src = source_for(cwd).ok_or("building a commit needs the beam-lisp checkout: set :source in the config")?;
            build_commit(store, &src, &c, me, &[]).map(|b| b.id)
        }
        Spec::BleedingEdge(which) => {
            let tree = match which {
                None => source_tree(cwd).or_else(source_repo),
                Some(x) => Some(std::fs::canonicalize(expand_home(&x)).map_err(|e| format!("{x}: {e}"))?),
            }
            .ok_or("no beam-lisp tree to build: run inside one, or name it (bleeding-edge:DIR)")?;
            build_tree(store, &tree, me, &[]).map(|b| b.id)
        }
        Spec::Build(id) => {
            if store.has(&id) { Ok(id) } else { Err(format!("build {id} is not stored and cannot be fetched by id")) }
        }
        Spec::Path(p) => {
            let tmp = store.meta().join("incoming").join(format!("import-{}", std::process::id()));
            let _ = std::fs::create_dir_all(tmp.parent().unwrap());
            std::fs::copy(&p, &tmp).map_err(|e| format!("{}: {e}", p.display()))?;
            publish_drop(store, &tmp)
        }
    }
}

// ── installing the launcher ─────────────────────────────────────────────────

/// Set `:key "value"` in the config text: replace it where it stands, else add
/// it before the closing brace (or start a map).
pub fn config_set(text: &str, key: &str, value: &str) -> String {
    let needle = format!(":{key} \"");
    if let Some(at) = text.find(&needle) {
        let start = at + needle.len();
        if let Some(end) = text[start..].find('"') {
            return format!("{}{}{}", &text[..start], value, &text[start + end..]);
        }
    }
    match text.rfind('}') {
        Some(close) => format!("{}\n :{key} \"{value}\"{}", text[..close].trim_end(), &text[close..]),
        None => format!(";; ~/.config/bl/config.bl — the PATH launcher's settings (read by scan, never evaluated).\n{{:{key} \"{value}\"}}\n"),
    }
}

/// `bl self-install [--source DIR]`: copy this launcher to `~/.local/bin/bl`
/// (`BL_INSTALL_BIN` overrides), atomically, replacing whatever was there — a
/// symlink into some checkout, or a drop someone copied. Records `:source`.
pub fn self_install(me: &Path, args: &[String], cwd: &Path) -> Result<String, String> {
    let dest = std::env::var("BL_INSTALL_BIN").map(PathBuf::from).unwrap_or_else(|_| expand_home("~/.local/bin/bl"));
    let mut report = vec![];
    let was = match std::fs::symlink_metadata(&dest) {
        Ok(m) if m.file_type().is_symlink() => Some(format!("a symlink to {}", std::fs::read_link(&dest).map(|p| p.display().to_string()).unwrap_or_default())),
        Ok(_) if try_read_trailer(&dest).is_some() => Some("a drop (a whole build copied onto PATH)".to_string()),
        Ok(_) => Some("an earlier launcher".to_string()),
        Err(_) => None,
    };
    if std::fs::canonicalize(&dest).ok() != std::fs::canonicalize(me).ok() {
        let tmp = dest.with_extension(format!("tmp-{}", std::process::id()));
        std::fs::create_dir_all(dest.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::copy(me, &tmp).map_err(|e| format!("copy to {}: {e}", tmp.display()))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
        }
        std::fs::rename(&tmp, &dest).map_err(|e| format!("install {}: {e}", dest.display()))?;
        report.push(format!("installed the launcher at {}{}", tildify(&dest), was.map(|w| format!(" (replacing {w})")).unwrap_or_default()));
    } else {
        report.push(format!("{} is already this launcher", tildify(&dest)));
    }

    let source = match args.iter().position(|a| a == "--source") {
        Some(i) => Some(std::fs::canonicalize(expand_home(args.get(i + 1).ok_or("--source needs a directory")?)).map_err(|e| e.to_string())?),
        None => source_tree(cwd).and_then(|t| main_worktree(&t)),
    };
    if let Some(src) = source {
        let path = config_path();
        let text = std::fs::read_to_string(&path).unwrap_or_default();
        write_atomic(&path, config_set(&text, "source", &src.to_string_lossy()).as_bytes()).map_err(|e| e.to_string())?;
        report.push(format!("builds come from {} (:source in {})", tildify(&src), tildify(&path)));
    }
    Ok(report.join("\n"))
}

#[cfg(test)]
mod builder_tests {
    use super::*;

    #[test]
    fn json_scan_reads_flat_strings() {
        let j = r#"{"url":"x","tag_name": "v2026.4","name":"v2026.4","prerelease":false}"#;
        assert_eq!(json_string(j, "tag_name").as_deref(), Some("v2026.4"));
        assert_eq!(json_string(j, "missing"), None);
    }

    #[test]
    fn config_set_replaces_or_adds() {
        let t = config_set("", "source", "/a");
        assert!(t.contains("{:source \"/a\"}"));
        assert_eq!(scan_literal(&t, "source").as_deref(), Some("/a"));
        let t2 = config_set(&t, "source", "/b");
        assert_eq!(scan_literal(&t2, "source").as_deref(), Some("/b"));
        let t3 = config_set(&t2, "default", "latest");
        assert_eq!(scan_literal(&t3, "default").as_deref(), Some("latest"));
        assert_eq!(scan_literal(&t3, "source").as_deref(), Some("/b"));
    }

    #[test]
    fn this_platform_has_an_asset_name() {
        if cfg!(all(target_os = "linux", target_arch = "x86_64")) {
            assert_eq!(asset_name(), Some("bl-linux-x86_64"));
        }
    }

    #[test]
    fn the_build_lock_is_exclusive_and_stale_locks_are_taken() {
        let d = std::env::temp_dir().join(format!("drop-lock-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let store = Store { root: d.clone() };
        let path = store.meta().join("locks").join("build");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "999999999").unwrap(); // a pid that cannot be alive
        {
            let _l = BuildLock::take(&store);
            assert_eq!(std::fs::read_to_string(&path).unwrap(), std::process::id().to_string());
        }
        assert!(!path.exists(), "the lock is released on drop");
        let _ = std::fs::remove_dir_all(&d);
    }
}
