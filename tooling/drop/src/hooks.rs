// hooks.rs — automatic updates and the `latest` guard, as git hooks.
// (included via include! into launcher.rs — no //! inner docs allowed here)
//
//   bl hooks install [DIR]   install into the repository at DIR (default: here)
//   bl hooks remove  [DIR]
//   bl hooks status  [DIR]   what is out of date, and why
//   bl hooks run EVENT       what an installed hook calls (internal)
//
// Two kinds of repository get hooks:
//
//   the beam-lisp checkout   post-commit / post-merge / post-checkout /
//                            post-rewrite CHECK whether the worktree's newest
//                            build still matches what a build reads, and print
//                            a warning when it does not. They never build: a
//                            build takes minutes and the lock is shared, so the
//                            decision to pay for one is the person's
//                            (`bl self-update bleeding-edge`, `bl self-update`).
//   a project on `latest`    pre-push refuses a push while the local beam-lisp
//                            `main` has commits `origin/main` does not: the
//                            project may use them, and nobody else's `latest`
//                            has them.
//
// A hook is a short `sh` script that calls `bl hooks run`. Existing hooks are
// never overwritten: the script calls the old one first (renamed
// `<name>.pre-bl`), then ours, so installing is additive and reversible.
//
// A hook starts nothing, so it can hold no descriptor open and hang `direnv`
// entry (~/.agents/AGENTS.md): it reads a few files, runs two git queries, and
// exits.

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
    let latest = std::fs::read_to_string(top.join(PROJECT_FILE))
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
            run_hook(store, event, &args[2.min(args.len())..], cwd)
        }
        "status" => {
            let top = source_tree(&target).ok_or("not inside a beam-lisp tree")?;
            let warnings = stale_report(store, &top);
            Ok(if warnings.is_empty() { format!("{}: every recorded build matches its inputs", tildify(&top)) } else { warnings.join("\n") })
        }
        other => Err(format!("bl hooks: unknown `{other}` (install | remove | status)")),
    }
}

/// What an installed hook does. Hooks never fail the git operation that fired
/// them and never build; the pre-push guard is the only hook that refuses.
fn run_hook(store: &Store, event: &str, rest: &[String], cwd: &Path) -> Result<String, String> {
    match event {
        "pre-push" => guard_latest(cwd).map(|_| String::new()),
        // post-checkout's third argument is 1 for a branch switch, 0 for a file
        // checkout: only a branch switch changes what the tree is.
        "post-checkout" if rest.get(2).map(String::as_str) == Some("0") => Ok(String::new()),
        e if SOURCE_EVENTS.contains(&e) => {
            let warnings = source_tree(cwd).map(|tree| stale_report(store, &tree)).unwrap_or_default();
            if !warnings.is_empty() {
                eprintln!("{}", warnings.join("\n"));
            }
            Ok(String::new())
        }
        _ => Ok(String::new()),
    }
}

// ── is a build warranted? ───────────────────────────────────────────────────

/// Why a recorded build no longer matches the tree, pure. `built` is the commit
/// the build was made from (None: no build recorded), `changed` whether a build
/// input differs between that commit and HEAD (None: git could not say, e.g.
/// the commit is gone). A build is warranted only when its inputs moved: a
/// commit that touches docs or tests does not make a build stale.
pub fn staleness(label: &str, built: Option<&str>, head: &str, changed: Option<bool>) -> Option<String> {
    let short = |c: &str| c.chars().take(8).collect::<String>();
    match (built, changed) {
        (None, _) => None, // nothing was ever built here: nothing to be behind
        (Some(c), _) if c == head => None,
        (Some(_), Some(false)) => None,
        (Some(c), Some(true)) => Some(format!("{label} was built from {}; build inputs have changed since ({})", short(c), short(head))),
        (Some(c), None) => Some(format!("{label} was built from {}, which this repository no longer has", short(c))),
    }
}

/// Whether any build input differs between commit `from` and HEAD of `tree`.
fn inputs_changed(tree: &Path, from: &str) -> Option<bool> {
    let mut args = vec!["diff", "--quiet", from, "HEAD", "--"];
    args.extend(BUILD_INPUTS);
    let status = git_at(tree).args(&args).stderr(Stdio::null()).status().ok()?;
    match status.code() {
        Some(0) => Some(false),
        Some(1) => Some(true),
        _ => None, // an unknown commit or any other git failure
    }
}

/// The warnings for `tree`: its own newest build, and, for the source
/// checkout on `main`, the `latest` channel. Empty when nothing is behind.
/// Uncommitted edits are not reported: they run from source.
pub fn stale_report(store: &Store, tree: &Path) -> Vec<String> {
    let Some(head) = git_out(tree, &["rev-parse", "HEAD"]) else { return vec![] };
    let mut targets = vec![("bleeding-edge", store.bleeding_edge_key(&tree_id(tree)))];
    if is_source_main(tree) {
        targets.push(("latest", store.channel_key("latest")));
    }
    let mut out: Vec<String> = targets
        .into_iter()
        .filter_map(|(label, key)| {
            let built = store.read(&key).and_then(|p| p.get("commit").map(str::to_string)).filter(|c| !c.is_empty());
            let changed = built.as_deref().and_then(|c| inputs_changed(tree, c));
            staleness(label, built.as_deref(), &head, changed).map(|w| format!("bl: {w}"))
        })
        .collect();
    if !out.is_empty() {
        out.push(format!("bl: when it suits you: `bl self-update bleeding-edge` in {}{}", tildify(tree), if is_source_main(tree) { ", then `bl self-update` for latest" } else { "" }));
    }
    out
}

/// The variables git sets for a hook so that git commands inside it act on the
/// repository that fired it. Exactly `git rev-parse --local-env-vars` (a test
/// keeps this table equal to what the installed git reports).
///
/// They must not reach the drainer: it builds OTHER trees, and with `GIT_DIR`
/// naming the worktree that committed, every `git -C <tree>` it ran read that
/// worktree's repository instead. Measured on the real build: a tree at
/// `9870f1e4` answered `rev-parse HEAD` as `6a67c2a6` (a feature-branch commit
/// that is not on main) when run under the hook's `GIT_DIR`, and `latest` was
/// stamped with it.
const GIT_LOCAL_ENV: &[&str] = &[
    "GIT_ALTERNATE_OBJECT_DIRECTORIES",
    "GIT_CONFIG",
    "GIT_CONFIG_PARAMETERS",
    "GIT_CONFIG_COUNT",
    "GIT_OBJECT_DIRECTORY",
    "GIT_DIR",
    "GIT_WORK_TREE",
    "GIT_IMPLICIT_WORK_TREE",
    "GIT_GRAFT_FILE",
    "GIT_INDEX_FILE",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_REPLACE_REF_BASE",
    "GIT_PREFIX",
    "GIT_SHALLOW_FILE",
    "GIT_COMMON_DIR",
];

/// Remove from `cmd` every variable that ties a git command to one repository.
fn scrub_git_env(cmd: &mut Command) {
    for var in GIT_LOCAL_ENV {
        cmd.env_remove(var);
    }
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
    let on_latest = std::fs::read_to_string(top.join(PROJECT_FILE))
        .ok()
        .and_then(|t| scan_literal(&t, "bl"))
        .is_some_and(|s| s == "latest");
    if !on_latest {
        return Ok(());
    }
    let Some(src) = source_repo() else {
        return Ok(()); // no local beam-lisp: this machine's latest IS CI's
    };
    let fetched = git_at(&src)
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
    fn a_git_command_run_from_a_hook_names_its_repository_by_path_alone() {
        let mut cmd = Command::new("true");
        scrub_git_env(&mut cmd);
        let removed: Vec<_> = cmd.get_envs().filter(|(_, v)| v.is_none()).map(|(k, _)| k.to_string_lossy().into_owned()).collect();
        for var in ["GIT_DIR", "GIT_INDEX_FILE", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_COMMON_DIR"] {
            assert!(removed.iter().any(|r| r == var), "{var} must be removed from a git command run on behalf of a hook");
        }
        assert_eq!(removed.len(), GIT_LOCAL_ENV.len());
    }

    #[test]
    fn the_scrubbed_list_is_what_git_calls_local() {
        let Some(out) = Command::new("git").args(["rev-parse", "--local-env-vars"]).output().ok().filter(|o| o.status.success()) else {
            return; // no git here: nothing to compare against
        };
        let theirs = String::from_utf8_lossy(&out.stdout);
        let missing: Vec<&str> = theirs.lines().map(str::trim).filter(|v| !v.is_empty() && !GIT_LOCAL_ENV.contains(v)).collect();
        assert!(missing.is_empty(), "git now reports local variables the drainer would inherit: {missing:?}");
    }

    #[test]
    fn a_build_is_warranted_only_when_its_inputs_moved() {
        // no build recorded → nothing to be behind
        assert_eq!(staleness("latest", None, "bbbbbbbb", None), None);
        // built from HEAD
        assert_eq!(staleness("latest", Some("bbbbbbbb"), "bbbbbbbb", Some(true)), None);
        // HEAD moved but only docs/tests did: the build is still right
        assert_eq!(staleness("latest", Some("aaaaaaaa"), "bbbbbbbb", Some(false)), None);
        // an input moved → warn, naming both commits
        let w = staleness("bleeding-edge", Some("aaaaaaaa11"), "bbbbbbbb22", Some(true)).unwrap();
        assert!(w.contains("bleeding-edge") && w.contains("aaaaaaaa") && w.contains("bbbbbbbb"), "{w}");
        // the build's commit is gone (rebase, gc): say so rather than staying silent
        assert!(staleness("latest", Some("aaaaaaaa"), "bbbbbbbb", None).unwrap().contains("no longer has"));
    }

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
