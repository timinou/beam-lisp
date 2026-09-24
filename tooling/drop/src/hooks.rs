// hooks.rs — automatic updates and the `latest` guard, as git hooks.
// (included via include! into launcher.rs — no //! inner docs allowed here)
//
//   bl hooks install [DIR]   install into the repository at DIR (default: here)
//   bl hooks remove  [DIR]
//   bl hooks run EVENT       what an installed hook calls (internal)
//
// Two kinds of repository get hooks:
//
//   the beam-lisp checkout   post-commit / post-merge / post-checkout /
//                            post-rewrite ask for a BACKGROUND build of the
//                            worktree that fired; one on the source repo's
//                            `main` also moves `latest`.
//   a project on `latest`    pre-push refuses a push while the local beam-lisp
//                            `main` has commits `origin/main` does not: the
//                            project may use them, and nobody else's `latest`
//                            has them.
//
// A hook is a short `sh` script that calls `bl hooks run`. Existing hooks are
// never overwritten: the script calls the old one first (renamed
// `<name>.pre-bl`), then ours, so installing is additive and reversible.
//
// Background work obeys this host's rules (~/.agents/AGENTS.md): a detached
// child closes fds 3-9 so it cannot hold a direnv pipe open, and nothing relies
// on `timeout`.

const HOOK_MARK: &str = "# managed by `bl hooks` (PLAN-144)";
const SOURCE_EVENTS: &[&str] = &["post-commit", "post-merge", "post-checkout", "post-rewrite"];

fn hook_script(event: &str, bl: &Path) -> String {
    format!(
        "#!/bin/sh\n{HOOK_MARK}\n\
         # Runs the hook that was here before, then asks bl. Remove with `bl hooks remove`.\n\
         here=$(dirname \"$0\")\n\
         if [ -x \"$here/{event}.pre-bl\" ]; then \"$here/{event}.pre-bl\" \"$@\" || exit $?; fi\n\
         BL=\"{bl}\"\n\
         [ -x \"$BL\" ] || BL=$(command -v bl) || exit 0\n\
         exec \"$BL\" hooks run {event} \"$@\"\n",
        bl = bl.display()
    )
}

/// The hooks directory of the repository at `dir` (shared by all worktrees),
/// honouring `core.hooksPath`.
fn hooks_dir(dir: &Path) -> Result<PathBuf, String> {
    let p = git_out(dir, &["rev-parse", "--path-format=absolute", "--git-path", "hooks"])
        .ok_or_else(|| format!("{} is not inside a git repository", dir.display()))?;
    Ok(PathBuf::from(p))
}

fn is_ours(path: &Path) -> bool {
    std::fs::read_to_string(path).map(|t| t.contains(HOOK_MARK)).unwrap_or(false)
}

fn install_hook(dir: &Path, event: &str, bl: &Path) -> Result<String, String> {
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let path = dir.join(event);
    let mut note = String::new();
    if path.exists() && !is_ours(&path) {
        let keep = dir.join(format!("{event}.pre-bl"));
        if keep.exists() {
            return Err(format!("{} exists, and so does {}; merge them by hand", path.display(), keep.display()));
        }
        std::fs::rename(&path, &keep).map_err(|e| e.to_string())?;
        note = format!(" (the existing hook still runs first, as {event}.pre-bl)");
    }
    write_atomic(&path, hook_script(event, bl).as_bytes()).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755));
    }
    Ok(format!("{event}{note}"))
}

fn remove_hook(dir: &Path, event: &str) -> Option<String> {
    let path = dir.join(event);
    if !is_ours(&path) {
        return None;
    }
    let _ = std::fs::remove_file(&path);
    let keep = dir.join(format!("{event}.pre-bl"));
    if keep.exists() {
        let _ = std::fs::rename(&keep, &path);
        return Some(format!("{event} (restored the earlier hook)"));
    }
    Some(event.to_string())
}

/// Which hooks a repository gets: a beam-lisp tree gets the build hooks; a
/// project whose env.bl says `:bl "latest"` gets the pre-push guard.
fn events_for(top: &Path) -> Vec<&'static str> {
    let mut ev = vec![];
    if source_tree(top).is_some() {
        ev.extend_from_slice(SOURCE_EVENTS);
    }
    let latest = std::fs::read_to_string(top.join("env.bl"))
        .ok()
        .and_then(|t| scan_literal(&t, "bl"))
        .is_some_and(|s| s == "latest");
    if latest {
        ev.push("pre-push");
    }
    ev
}

pub fn hooks_verb(store: &Store, args: &[String], me: &Path, cwd: &Path) -> Result<String, String> {
    let sub = args.first().map(String::as_str).unwrap_or("install");
    let target = args.get(1).map(|d| expand_home(d)).unwrap_or_else(|| cwd.to_path_buf());
    match sub {
        "install" => {
            let top = PathBuf::from(git_out(&target, &["rev-parse", "--show-toplevel"]).ok_or("not inside a git repository")?);
            let dir = hooks_dir(&top)?;
            let events = events_for(&top);
            if events.is_empty() {
                return Ok(format!(
                    "{}: nothing to install (not a beam-lisp tree, and env.bl does not say :bl \"latest\")",
                    tildify(&top)
                ));
            }
            let done: Result<Vec<String>, String> = events.iter().map(|e| install_hook(&dir, e, me)).collect();
            Ok(format!("{}: installed {}", tildify(&dir), done?.join(", ")))
        }
        "remove" => {
            let dir = hooks_dir(&target)?;
            let gone: Vec<String> = SOURCE_EVENTS.iter().chain(["pre-push"].iter()).filter_map(|e| remove_hook(&dir, e)).collect();
            Ok(if gone.is_empty() { "no bl hooks here".to_string() } else { format!("removed {}", gone.join(", ")) })
        }
        "run" => {
            let event = args.get(1).map(String::as_str).unwrap_or("");
            run_hook(store, event, &args[2.min(args.len())..], me, cwd)
        }
        other => Err(format!("bl hooks: unknown `{other}` (install | remove)")),
    }
}

/// What an installed hook does. Build hooks never fail the git operation that
/// fired them; the pre-push guard is the only hook that refuses.
fn run_hook(store: &Store, event: &str, rest: &[String], me: &Path, cwd: &Path) -> Result<String, String> {
    match event {
        "pre-push" => guard_latest(cwd).map(|_| String::new()),
        // post-checkout's third argument is 1 for a branch switch, 0 for a file
        // checkout: only a branch switch changes what the tree is.
        "post-checkout" if rest.get(2).map(String::as_str) == Some("0") => Ok(String::new()),
        e if SOURCE_EVENTS.contains(&e) => {
            if let Some(tree) = source_tree(cwd) {
                request_build(store, &tree, me);
            }
            Ok(String::new())
        }
        _ => Ok(String::new()),
    }
}

/// Queue a background build of `tree`: at most one queued per tree; a newer
/// request while one is running is picked up when it finishes (the builder
/// re-reads the stamp, so a burst of commits builds once for the last state).
pub fn request_build(store: &Store, tree: &Path, me: &Path) {
    if std::env::var("BL_AUTOBUILD").as_deref() == Ok("off") {
        return;
    }
    let queue = store.meta().join("queue");
    let _ = std::fs::create_dir_all(&queue);
    let _ = write_atomic(&queue.join(tree_id(tree)), tree.to_string_lossy().as_bytes());
    spawn_detached(me, &["hooks", "drain"], tree);
}

/// Start `me ARGS` fully detached: its own process group, stdio on /dev/null,
/// and NO descriptor beyond 0-2. The last part is the one that matters: a
/// hook runs under git, git runs under whatever started it, and descriptors
/// that are not close-on-exec ride all the way down (measured: a drainer held
/// its caller's log and session files as fds 14 and 44). A long-lived child
/// holding a pipe it inherited is what hangs `direnv` entry on this host
/// (~/.agents/AGENTS.md), so every one above 2 is closed before exec.
fn spawn_detached(me: &Path, args: &[&str], cwd: &Path) {
    let mut cmd = Command::new(me);
    cmd.args(args).current_dir(cwd).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
        // SAFETY: runs in the forked child before exec; it only calls
        // `close`, which is async-signal-safe, and allocates nothing.
        unsafe {
            cmd.pre_exec(|| {
                close_fds_above_2();
                Ok(())
            });
        }
    }
    let _ = cmd.spawn();
}

#[cfg(unix)]
extern "C" {
    fn close(fd: i32) -> i32;
}

/// Close every descriptor above 2. Called between fork and exec, so it may not
/// allocate: it walks a fixed range rather than listing `/proc/self/fd`.
#[cfg(unix)]
fn close_fds_above_2() {
    for fd in 3..4096 {
        // SAFETY: closing a descriptor that is not open returns EBADF, nothing more.
        unsafe {
            close(fd);
        }
    }
}

/// `bl hooks drain`: build every queued tree, one at a time, until the queue is
/// empty. A second drainer finds the build lock held and leaves: the running
/// one re-reads the queue before it exits.
pub fn drain(store: &Store, me: &Path) -> Result<String, String> {
    let queue = store.meta().join("queue");
    let lock = store.meta().join("locks").join("drain");
    let _ = std::fs::create_dir_all(lock.parent().unwrap());
    if std::fs::OpenOptions::new().write(true).create_new(true).open(&lock).is_err() {
        let holder = std::fs::read_to_string(&lock).ok().and_then(|s| s.trim().parse::<u32>().ok());
        if holder.is_some_and(|p| Path::new(&format!("/proc/{p}")).exists()) {
            return Ok("a drainer is already running".to_string());
        }
        let _ = std::fs::remove_file(&lock);
        return drain(store, me);
    }
    let _ = std::fs::write(&lock, std::process::id().to_string());
    let mut built = vec![];
    loop {
        let next = std::fs::read_dir(&queue)
            .ok()
            .and_then(|rd| rd.flatten().find(|e| !e.file_name().to_string_lossy().contains(".tmp-")));
        let Some(entry) = next else { break };
        let tree = PathBuf::from(std::fs::read_to_string(entry.path()).unwrap_or_default().trim());
        let _ = std::fs::remove_file(entry.path());
        if source_tree(&tree).is_none() {
            continue;
        }
        // `latest` is main's COMMIT, never a working tree: a worktree build is
        // its bleeding-edge, and it is `latest` too only when it was clean.
        // Otherwise main's commit is built on its own, exactly as
        // `bl self-update latest` builds it.
        let on_main = is_source_main(&tree);
        match build_tree(store, &tree, me, &[]) {
            Ok(b) => {
                built.push(format!("{} → {}", tildify(&tree), b.id));
                if on_main {
                    let clean = b.key.as_deref().is_some_and(|k| !k.contains('+'));
                    let latest = if clean {
                        store.read(&format!("bleeding-edge/{}", tree_id(&tree)))
                            .map(|p| store.write("channels/latest", &p).map(|_| b.id.clone()).map_err(|e| e.to_string()))
                            .unwrap_or_else(|| Err("the build left no pointer".to_string()))
                    } else {
                        build_commit(store, &tree, "main", me, &["channels/latest"]).map(|l| l.id)
                    };
                    match latest {
                        Ok(id) => built.push(format!("latest → {id}")),
                        Err(e) => built.push(format!("latest: {e}")),
                    }
                }
            }
            Err(e) => built.push(format!("{}: {e}", tildify(&tree))),
        }
    }
    let _ = std::fs::remove_file(&lock);
    Ok(built.join("\n"))
}

/// Whether `tree` is the configured source checkout, on `main`.
fn is_source_main(tree: &Path) -> bool {
    let src = source_repo().and_then(|s| std::fs::canonicalize(s).ok());
    src.as_deref() == Some(tree) && head_branch(tree).as_deref() == Some("main")
}

// ── the `latest` guard ──────────────────────────────────────────────────────

/// The pre-push decision, pure: how many local `main` commits origin lacks.
pub fn guard_verdict(ahead: Option<u32>, fetched: bool, override_set: bool) -> Result<Option<String>, String> {
    let stale = if fetched { "" } else { " (could not fetch origin; compared against the last fetched origin/main)" };
    match ahead {
        _ if override_set => Ok(None),
        None => Ok(Some("bl: could not compare beam-lisp main with origin/main; pushing anyway".to_string())),
        Some(0) => Ok(None),
        Some(n) => Err(format!(
            "bl: this project runs `latest`, and your beam-lisp main is {n} commit(s) ahead of origin/main{stale}.\n\
             bl: this push may depend on them, and no one else's `latest` (nor CI's) has them.\n\
             bl: push beam-lisp main first, or pin :bl \"commit:<sha>\" in env.bl for now.\n\
             bl: to push anyway: BL_ALLOW_UNPUSHED_LATEST=1 git push   (or git push --no-verify)"
        )),
    }
}

fn guard_latest(cwd: &Path) -> Result<(), String> {
    let top = git_out(cwd, &["rev-parse", "--show-toplevel"]).map(PathBuf::from).unwrap_or_else(|| cwd.to_path_buf());
    let on_latest = std::fs::read_to_string(top.join("env.bl"))
        .ok()
        .and_then(|t| scan_literal(&t, "bl"))
        .is_some_and(|s| s == "latest");
    if !on_latest {
        return Ok(());
    }
    let Some(src) = source_repo() else {
        return Ok(()); // no local beam-lisp: this machine's latest IS CI's
    };
    let fetched = Command::new("git")
        .arg("-C")
        .arg(&src)
        .args(["fetch", "--quiet", "origin", "main"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|s| s.success());
    let ahead = git_out(&src, &["rev-list", "--count", "origin/main..main"]).and_then(|s| s.parse().ok());
    let allow = std::env::var("BL_ALLOW_UNPUSHED_LATEST").is_ok_and(|v| !v.is_empty() && v != "0");
    match guard_verdict(ahead, fetched, allow)? {
        Some(warn) => {
            eprintln!("{warn}");
            Ok(())
        }
        None => Ok(()),
    }
}

#[cfg(test)]
mod hooks_tests {
    use super::*;

    #[test]
    fn the_guard_refuses_only_unpushed_main() {
        assert_eq!(guard_verdict(Some(0), true, false), Ok(None));
        assert!(guard_verdict(Some(3), true, false).unwrap_err().contains("3 commit(s) ahead"));
        assert!(guard_verdict(Some(1), false, false).unwrap_err().contains("could not fetch"));
        assert_eq!(guard_verdict(Some(3), true, true), Ok(None), "the override lets it through");
        assert!(guard_verdict(None, true, false).unwrap().unwrap().contains("pushing anyway"));
    }

    #[test]
    fn install_keeps_an_existing_hook_and_remove_restores_it() {
        let d = std::env::temp_dir().join(format!("drop-hooks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        std::fs::write(d.join("post-commit"), "#!/bin/sh\necho theirs\n").unwrap();
        let bl = Path::new("/usr/local/bin/bl");

        let r = install_hook(&d, "post-commit", bl).unwrap();
        assert!(r.contains("pre-bl"));
        assert!(is_ours(&d.join("post-commit")));
        assert_eq!(std::fs::read_to_string(d.join("post-commit.pre-bl")).unwrap(), "#!/bin/sh\necho theirs\n");
        let script = std::fs::read_to_string(d.join("post-commit")).unwrap();
        assert!(script.contains("post-commit.pre-bl") && script.contains("hooks run post-commit"));

        install_hook(&d, "post-commit", bl).unwrap(); // idempotent
        assert_eq!(std::fs::read_to_string(d.join("post-commit.pre-bl")).unwrap(), "#!/bin/sh\necho theirs\n");

        remove_hook(&d, "post-commit").unwrap();
        assert_eq!(std::fs::read_to_string(d.join("post-commit")).unwrap(), "#!/bin/sh\necho theirs\n");
        assert!(!d.join("post-commit.pre-bl").exists());
        let _ = std::fs::remove_dir_all(&d);
    }
}
