// Checkout entry for the same native transport used by installed drops.
// Kept in this binary so framing, ownership and unknown-outcome rules stay shared.
fn checkout_root() -> Option<PathBuf> {
    std::env::var_os("BL_CHECKOUT_ROOT").map(PathBuf::from)
}

fn checkout_main(args: &[String]) -> ! {
    let root = args
        .first()
        .and_then(|s| std::fs::canonicalize(s).ok())
        .filter(|p| p.join("priv/bootstrap/seed/manifest.term").is_file())
        .unwrap_or_else(|| fail("--checkout requires a beam-lisp checkout"));
    if args.get(1).map(String::as_str) != Some("--") {
        fail("usage: drop-launcher --checkout ROOT -- ARGV...");
    }
    let argv = &args[2..];
    let cwd = std::env::current_dir().unwrap_or_else(|e| fail(&e.to_string()));
    let project = root_override(argv)
        .or_else(|| project_dir(&cwd))
        .unwrap_or_else(|| cwd.clone());
    let project = std::fs::canonicalize(project).unwrap_or_else(|e| fail(&e.to_string()));
    let extra_sources = checkout_extra_sources(&project, &request_cwd(&cwd, argv), argv);
    let generation = checkout_generation_with_paths(&root, &project, &extra_sources)
        .unwrap_or_else(|e| fail(&format!("checkout source inventory: {e}")));
    std::env::set_var("BL_CHECKOUT_ROOT", &root);
    std::env::set_var("BL_CHECKOUT_GENERATION", generation);
    exec_payload(&root, "src", argv)
}

fn invocation_tree(cwd: &Path, argv: &[String], checkout: bool) -> Option<PathBuf> {
    if !checkout {
        return tree_root(cwd, argv);
    }
    root_override(argv)
        .and_then(canonical_or)
        .or_else(|| project_dir(cwd))
        .or_else(|| resolve_root(cwd))
}

fn checkout_transport(argv: &[String], tree: Option<&str>, config: Option<&str>) -> Transport {
    // These commands publish the application image or provision its dependencies.
    // Their compiler lifetime belongs to a fresh process.
    if verb_of(argv)
        .as_deref()
        .is_some_and(|v| ["build", "self-build", "seed", "deps"].contains(&v))
    {
        return Transport::Cold;
    }
    declared_transport(argv, tree, config).unwrap_or(Transport::Require)
}

// Lifecycle control remains authenticated but can stop the previous source
// generation. It never sends a business request or retries one after send.
#[cfg(unix)]
fn stop_checkout_daemon(root: &Path) -> bool {
    let build = hello_build();
    let mut stream = match hello_generation(root, &build, false, None) {
        Hello::Ready(stream, generation) => {
            if generation.as_deref()
                == std::env::var("BL_CHECKOUT_GENERATION")
                    .ok()
                    .as_deref()
                    .map(str::as_bytes)
            {
                return true; // A concurrent client already replaced the outdated VM.
            }
            stream
        }
        Hello::No => return true,
        _ => return false,
    };
    let mut e = Enc::new();
    e.tuple_header(5);
    e.atom("bl");
    e.small_int(1);
    e.atom("control");
    e.binary(&request_id());
    e.atom("stop");
    if send_frame(&mut stream, &e.finish()).is_err() {
        return false;
    }
    loop {
        match recv_frame(&mut stream)
            .ok()
            .and_then(|bytes| decode(&bytes))
        {
            Some(Term::Tuple(t)) if t.len() == 5 && t[2].as_atom() == Some("exit") => break,
            Some(_) => continue,
            None => break,
        }
    }
    for _ in 0..250 {
        match hello_generation(root, &build, false, None) {
            Hello::No => return true,
            Hello::Ready(_, generation)
                if generation.as_deref()
                    == std::env::var("BL_CHECKOUT_GENERATION")
                        .ok()
                        .as_deref()
                        .map(str::as_bytes) =>
            {
                return true
            }
            _ => {}
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

fn checkout_memory_bound(command: Command) -> Command {
    #[cfg(target_os = "linux")]
    {
        let runtime = PathBuf::from(format!("/run/user/{}", unsafe { libc_getuid() }));
        if runtime.join("systemd/private").exists() {
            return checkout_scope(command);
        }
    }
    command
}

fn checkout_scope(command: Command) -> Command {
    let mut bounded = Command::new("systemd-run");
    bounded.arg(format!(
        "--unit=bl-checkout-{}-{}",
        std::process::id(),
        now_secs()
    ));
    bounded.args([
        "--user",
        "--scope",
        "--quiet",
        "--collect",
        "--property=MemoryMax=4G",
        "--property=MemorySwapMax=512M",
        "--",
    ]);
    // systemd-run resolves its bus using XDG_RUNTIME_DIR. Restore the caller's
    // original runtime directory only in the executed CLI (including test sockets).
    bounded.args(["env", "-u", "XDG_RUNTIME_DIR"]);
    if let Some(value) = std::env::var_os("XDG_RUNTIME_DIR") {
        let mut assignment = std::ffi::OsString::from("XDG_RUNTIME_DIR=");
        assignment.push(value);
        bounded.arg(assignment);
    }
    bounded.arg(command.get_program()).args(command.get_args());
    for (key, value) in command.get_envs() {
        if let Some(value) = value {
            bounded.env(key, value);
        } else {
            bounded.env_remove(key);
        }
    }
    bounded.env(
        "XDG_RUNTIME_DIR",
        format!("/run/user/{}", unsafe { libc_getuid() }),
    );
    if let Some(dir) = command.get_current_dir() {
        bounded.current_dir(dir);
    }
    bounded
}

#[cfg(test)]
fn checkout_generation(root: &Path, project: &Path) -> std::io::Result<String> {
    checkout_generation_with_paths(
        root,
        project,
        &checkout_extra_sources(project, project, &[]),
    )
}

fn checkout_extra_sources(project: &Path, cwd: &Path, argv: &[String]) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for file in ["env.bl", ".env.local.bl"] {
        if let Ok(text) = std::fs::read_to_string(project.join(file)) {
            let tokens = literal_tokens(&text);
            for (i, (depth, key)) in tokens.iter().enumerate() {
                let Some((_, next)) = tokens.get(i + 1) else {
                    continue;
                };
                if key == ":paths" && next == "[" {
                    for (d, value) in &tokens[i + 2..] {
                        if d <= depth {
                            break;
                        }
                        if let Some(value) =
                            value.strip_prefix('"').and_then(|v| v.strip_suffix('"'))
                        {
                            roots.push(project.join(value));
                        }
                    }
                } else if [":path", ":run"].contains(&key.as_str()) {
                    if let Some(value) = next.strip_prefix('"').and_then(|v| v.strip_suffix('"')) {
                        roots.push(project.join(value));
                    }
                }
            }
        }
    }
    for path in collect_env_paths() {
        roots.push(cwd.join(path));
    }
    let mut i = 0;
    while i < argv.len() && argv[i] != "--" {
        if ["-p", "--path", "--code-path"].contains(&argv[i].as_str()) {
            if let Some(path) = argv.get(i + 1) {
                roots.push(cwd.join(path));
            }
            i += 1;
        }
        i += 1;
    }
    roots
}

fn checkout_generation_with_paths(
    root: &Path,
    project: &Path,
    extra_sources: &[PathBuf],
) -> std::io::Result<String> {
    use sha2::{Digest, Sha256};
    let mut files = Vec::new();
    checkout_sources(&root.join("priv"), &mut files)?;
    checkout_sources(&root.join("native"), &mut files)?;
    checkout_sources(project, &mut files)?;
    for path in extra_sources {
        checkout_sources(path, &mut files)?;
    }
    for name in [
        "bin/bl",
        "bin/bl-stage-hosts",
        "priv/bootstrap/seed/manifest.term",
        "priv/codegen.sources",
        ".cargo/config.toml",
        ".cargo/config",
        "rust-toolchain.toml",
        "rust-toolchain",
    ] {
        if root.join(name).is_file() {
            files.push(root.join(name));
        }
    }
    // An explicit application image is part of this invocation's authority.
    if let Some(ebin) = std::env::var_os("BEAM_LISP_EBIN") {
        checkout_sources(&PathBuf::from(ebin), &mut files)?;
    }
    files.sort();
    files.dedup();
    let mut hash = Sha256::new();
    hash.update(b"checkout-generation-v1\0");
    hash.update(root.as_os_str().as_encoded_bytes());
    for key in [
        "HOME",
        "XDG_DATA_HOME",
        "ERL_FLAGS",
        "ERL_AFLAGS",
        "ELIXIR_ERL_OPTIONS",
        "BEAM_LISP_AOT_BACKEND",
        "BEAM_LISP_AOT_CACHE_DIR",
        "BEAM_LISP_AOT_CACHE",
        "BEAM_LISP_AOT_STRICT",
        "BEAM_LISP_DEV",
        "XDG_CACHE_HOME",
        "BEAM_LISP_EBIN",
        "BEAM_LISP_PATH",
        "BL_BOOTSTRAP_SEED",
    ] {
        hash.update(key.as_bytes());
        hash.update([0]);
        hash.update(std::env::var_os(key).unwrap_or_default().as_encoded_bytes());
        hash.update([0]);
    }
    for path in files {
        let mut input = std::fs::File::open(&path)?;
        let mut content = Sha256::new();
        let mut buffer = [0u8; 65536];
        loop {
            let count = std::io::Read::read(&mut input, &mut buffer)?;
            if count == 0 {
                break;
            }
            content.update(&buffer[..count]);
        }
        let canonical = std::fs::canonicalize(&path)?;
        let physical = canonical.as_os_str().as_encoded_bytes();
        hash.update((physical.len() as u64).to_be_bytes());
        hash.update(physical);
        let name = path.as_os_str().as_encoded_bytes();
        hash.update((name.len() as u64).to_be_bytes());
        hash.update(name);
        hash.update(content.finalize());
    }
    Ok(format!("{:x}", hash.finalize()))
}

fn checkout_sources(dir: &Path, files: &mut Vec<PathBuf>) -> std::io::Result<()> {
    checkout_sources_walk(dir, files, &mut std::collections::BTreeSet::new())
}

fn checkout_sources_walk(
    dir: &Path,
    files: &mut Vec<PathBuf>,
    visited: &mut std::collections::BTreeSet<PathBuf>,
) -> std::io::Result<()> {
    if !dir.exists() {
        return Ok(());
    }
    if dir.is_file() {
        files.push(dir.to_path_buf());
        return Ok(());
    }
    if !visited.insert(std::fs::canonicalize(dir)?) {
        return Ok(());
    }
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        let name = entry.file_name();
        let name = name.to_string_lossy();
        let kind = entry.file_type()?;
        if kind.is_dir() || (kind.is_symlink() && path.is_dir()) {
            if (!name.starts_with('.') || name == ".cargo")
                && !(name == "build" && dir.file_name().is_none_or(|n| n != "priv"))
                && !["_build", "target", "deps", "node_modules", "tmp"].contains(&name.as_ref())
            {
                checkout_sources_walk(&path, files, visited)?;
            }
        } else if (kind.is_file() || (kind.is_symlink() && path.is_file()))
            && (name.ends_with(".bl")
                || name.ends_with(".bl.md")
                || name.ends_with(".bl.org")
                || name.ends_with(".rs")
                || name.ends_with(".so")
                || name.ends_with(".beam")
                || name == "Cargo.toml"
                || name == "Cargo.lock"
                || name == "sdk-code.term"
                || name == "rust-toolchain.toml"
                || name == "rust-toolchain"
                || (dir.file_name().is_some_and(|n| n == ".cargo")
                    && ["config", "config.toml"].contains(&name.as_ref()))
                || (dir.file_name().is_some_and(|n| n == "native")
                    && dir
                        .parent()
                        .and_then(Path::file_name)
                        .is_some_and(|n| n == "priv")))
        {
            files.push(path);
        }
    }
    Ok(())
}

#[cfg(test)]
mod checkout_tests {
    use super::*;

    #[test]
    fn declared_hidden_and_external_source_paths_are_inventoried() {
        let root = std::env::temp_dir().join(format!("checkout-paths-{}", std::process::id()));
        let project = root.join("project");
        std::fs::create_dir_all(project.join(".local/lib")).unwrap();
        std::fs::create_dir_all(root.join("shared")).unwrap();
        std::fs::write(root.join("shared/value.bl"), "(ns shared.value)").unwrap();
        std::fs::write(project.join("env.bl"), r#"{:paths [".local/lib"] :uses {"shared" {:path "../shared"}} :tasks {:go {:run "../task.bl"}}}"#).unwrap();
        let roots = checkout_extra_sources(&project, &project, &[]);
        assert!(roots.contains(&project.join(".local/lib")));
        assert!(roots.contains(&project.join("../shared")));
        assert!(roots.contains(&project.join("../task.bl")));
        let before = checkout_generation(&root, &project).unwrap();
        std::fs::write(project.join(".local/lib/example.bl"), "(ns example)").unwrap();
        assert_ne!(before, checkout_generation(&root, &project).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn memory_scope_preserves_argv_environment_and_directory() {
        let mut command = Command::new("/checkout with spaces/bin/bl");
        command
            .args(["realm", "start", "--root", "/project with spaces"])
            .env("BL_CHECKOUT_COLD", "/checkout with spaces")
            .env_remove("UNSET_TEST_ENV")
            .current_dir("/tmp");
        let bounded = checkout_scope(command);
        let args = bounded
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect::<Vec<_>>();
        assert!(args.contains(&"--property=MemoryMax=4G".to_string()));
        assert_eq!(
            &args[args.len() - 5..],
            [
                "/checkout with spaces/bin/bl",
                "realm",
                "start",
                "--root",
                "/project with spaces"
            ]
        );
        assert!(bounded.get_envs().any(|(k, v)| k == "BL_CHECKOUT_COLD"
            && v == Some(std::ffi::OsStr::new("/checkout with spaces"))));
        assert!(bounded
            .get_envs()
            .any(|(k, v)| k == "UNSET_TEST_ENV" && v.is_none()));
        assert_eq!(bounded.get_current_dir(), Some(Path::new("/tmp")));
    }

    #[test]
    fn subdirectories_use_the_project_endpoint() {
        let root = std::env::temp_dir().join(format!("checkout-tree-{}", std::process::id()));
        std::fs::create_dir_all(root.join("nested")).unwrap();
        std::fs::write(root.join("env.bl"), "{}").unwrap();
        assert_eq!(
            invocation_tree(&root.join("nested"), &[], true),
            Some(root.clone())
        );
        let argv = vec![
            "--root".to_string(),
            root.join("nested").to_string_lossy().into_owned(),
        ];
        assert_eq!(
            invocation_tree(&root, &argv, true),
            Some(root.join("nested"))
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn checkout_defaults_to_one_persistent_owner_and_honors_cold_policy() {
        assert_eq!(checkout_transport(&[], None, None), Transport::Require);
        let args = |words: &[&str]| words.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert_eq!(
            checkout_transport(&args(&["--cold", "eval", "1"]), None, None),
            Transport::Cold
        );
        assert_eq!(
            checkout_transport(&[], Some(":warm \"attach\""), None),
            Transport::Attach
        );
        for verb in ["build", "self-build", "seed", "deps"] {
            assert_eq!(
                checkout_transport(&args(&["--warm", verb]), None, None),
                Transport::Cold
            );
        }
    }

    #[test]
    fn generation_tracks_content_additions_deletions_and_checkout_identity() {
        let root = std::env::temp_dir().join(format!("checkout-generation-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for dir in ["priv/bootstrap/seed", "native", "bin", "project"] {
            std::fs::create_dir_all(root.join(dir)).unwrap();
        }
        for file in [
            "bin/bl",
            "bin/bl-stage-hosts",
            "priv/bootstrap/seed/manifest.term",
            "priv/codegen.sources",
        ] {
            std::fs::write(root.join(file), "fixture").unwrap();
        }
        let project = root.join("project");
        let key = || checkout_generation(&root, &project).unwrap();
        let first = key();
        let source = project.join("a.bl");
        std::fs::write(&source, "(def a 1)").unwrap();
        let added = key();
        assert_ne!(first, added);
        std::fs::write(&source, "(def a 2)").unwrap();
        assert_ne!(added, key());
        std::fs::remove_file(source).unwrap();
        assert_eq!(first, key());
        std::fs::create_dir(project.join("build")).unwrap();
        std::fs::write(project.join("build/generated.bl"), "ignored").unwrap();
        assert_eq!(first, key());
        std::fs::write(
            root.join("priv/bootstrap/seed/manifest.term"),
            "different floor",
        )
        .unwrap();
        assert_ne!(first, key());
        std::fs::remove_dir_all(root).unwrap();
    }
}
