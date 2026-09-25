// store.rs — the build store and the resolver the PATH launcher runs.
// (included via include! into launcher.rs — no //! inner docs allowed here)
//
// ONE `bl` on PATH, many builds behind it. The PATH `bl` is this launcher with
// NO payload; on every call it answers "which build runs here?" and then runs
// that build exactly as a drop would. docs/native-bundler.md §15 is the prose.
//
// The store lives beside the extracted payloads (`install_dir()`):
//
//   <install>/<sha8>/                      an extracted payload (unchanged)
//   <install>/store/blobs/<sha8>.drop      the sealed drop file of a build
//   <install>/store/channels/stable        pointer files (see `Pointer`)
//   <install>/store/channels/latest
//   <install>/store/bleeding-edge/<tree-id>  the newest build of ONE worktree,
//                                          with the stamp it was built from
//   <install>/store/tags/<vX.Y.Z>
//   <install>/store/sources/<source-key>   commit (+diff) → build
//
// Every write is temp + rename: a reader sees the old pointer or the new one.
//
// THE LAUNCHER NEVER RUNS GIT. A worktree's build is recognised by its STAMP
// (`stamp`): a hash over the build inputs' paths, sizes and mtimes plus the
// commit HEAD names. Measured on this host under load: an in-process walk of the
// inputs is ~2-3 ms; spawning even `/bin/true` is 56-196 ms, and `git status`
// 60-112 ms. The stamp is recorded when a build is published, so matching it is
// a comparison, and any edit since is a mismatch — which runs the tree from
// source, the always-correct answer.

// `Path`/`PathBuf` come from daemon.rs, included before this file.

/// The inputs a build is made from. MUST equal `provenance/INPUTS`
/// (priv/build/provenance.bl); `store_tests::inputs_match_provenance` holds it.
pub const BUILD_INPUTS: &[&str] = &[
    "lib",
    "priv",
    "native",
    "tooling/drop/src",
    "tooling/drop/Cargo.toml",
    "tooling/drop/Cargo.lock",
    "bin",
    "env.bl",
    "bl.lock",
];

/// Build OUTPUTS that live under an input root (all gitignored). Skipping them
/// keeps a build's own products from changing the stamp of the tree it built.
const STAMP_SKIP_DIRS: &[&str] = &["target", ".spell", ".cargo"];
const STAMP_SKIP_PATHS: &[&str] = &["priv/native", "priv/embed", "priv/z3", "priv/codegen.sources"];

// ── the store ───────────────────────────────────────────────────────────────

pub struct Store {
    pub root: PathBuf,
}

impl Store {
    pub fn open() -> Store {
        Store { root: install_dir() }
    }

    pub fn meta(&self) -> PathBuf {
        self.root.join("store")
    }

    pub fn blob(&self, id: &str) -> PathBuf {
        self.meta().join("blobs").join(format!("{id}.drop"))
    }

    pub fn payload(&self, id: &str) -> PathBuf {
        self.root.join(id)
    }

    /// Whether build `id` can be run: its payload is extracted, or its sealed
    /// drop is stored and can be.
    pub fn has(&self, id: &str) -> bool {
        self.payload(id).join("bin").exists() || self.blob(id).is_file()
    }

    pub fn read(&self, rel: &str) -> Option<Pointer> {
        let text = std::fs::read_to_string(self.meta().join(rel)).ok()?;
        Pointer::parse(&text)
    }

    pub fn write(&self, rel: &str, p: &Pointer) -> std::io::Result<()> {
        write_atomic(&self.meta().join(rel), p.render().as_bytes())
    }
}

/// Write `bytes` to `path` through a sibling temp file and a rename.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension(format!("tmp-{}", std::process::id()));
    std::fs::write(&tmp, bytes)?;
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// A pointer file: `key value` lines. `build` is required; the rest describe
/// where it came from (`stamp`, `key`, `root`, `branch`, `commit`).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Pointer {
    pub build: String,
    pub fields: Vec<(String, String)>,
}

impl Pointer {
    pub fn new(build: &str) -> Pointer {
        Pointer { build: build.to_string(), fields: vec![] }
    }

    pub fn with(mut self, k: &str, v: &str) -> Pointer {
        if !v.is_empty() {
            self.fields.push((k.to_string(), v.to_string()));
        }
        self
    }

    pub fn get(&self, k: &str) -> Option<&str> {
        self.fields.iter().find(|(key, _)| key == k).map(|(_, v)| v.as_str())
    }

    pub fn parse(text: &str) -> Option<Pointer> {
        let mut p = Pointer::default();
        for line in text.lines() {
            let Some((k, v)) = line.split_once(' ') else { continue };
            let v = v.trim();
            if k == "build" {
                p.build = v.to_string();
            } else if !k.is_empty() {
                p.fields.push((k.to_string(), v.to_string()));
            }
        }
        is_build_id(&p.build).then_some(p)
    }

    pub fn render(&self) -> String {
        let mut s = format!("build {}\n", self.build);
        for (k, v) in &self.fields {
            s.push_str(&format!("{k} {v}\n"));
        }
        s
    }
}

/// A build id is a payload's sha8: exactly 8 lowercase hex digits.
pub fn is_build_id(s: &str) -> bool {
    s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

// ── the stamp ───────────────────────────────────────────────────────────────

/// The stamp of the source tree at `root`: sha256 over every build input's
/// relative path, size and mtime (sorted), plus the commit HEAD resolves to.
/// Equal stamps mean nothing a build reads has been touched.
pub fn stamp(root: &Path) -> String {
    let mut rows: Vec<String> = Vec::with_capacity(512);
    for input in BUILD_INPUTS {
        walk_input(root, &root.join(input), &mut rows);
    }
    rows.sort();
    rows.push(format!("HEAD {}", head_commit(root).unwrap_or_default()));
    sha256_hex(rows.join("\n").as_bytes())
}

fn walk_input(root: &Path, path: &Path, rows: &mut Vec<String>) {
    let Ok(md) = std::fs::symlink_metadata(path) else { return };
    let rel = path.strip_prefix(root).unwrap_or(path).to_string_lossy().into_owned();
    if STAMP_SKIP_PATHS.contains(&rel.as_str()) {
        return;
    }
    if md.is_dir() {
        let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        if STAMP_SKIP_DIRS.contains(&name.as_str()) {
            return;
        }
        if let Ok(rd) = std::fs::read_dir(path) {
            for e in rd.flatten() {
                walk_input(root, &e.path(), rows);
            }
        }
    } else {
        let mtime = md
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_nanos())
            .unwrap_or(0);
        rows.push(format!("{rel}\t{}\t{mtime}", md.len()));
    }
}

/// The git dir of the work tree at `root`: `.git` itself, or the directory a
/// worktree's `.git` FILE points at.
pub fn git_dir(root: &Path) -> Option<PathBuf> {
    let dot = root.join(".git");
    if dot.is_dir() {
        return Some(dot);
    }
    let text = std::fs::read_to_string(&dot).ok()?;
    let p = PathBuf::from(text.strip_prefix("gitdir:")?.trim());
    Some(if p.is_absolute() { p } else { root.join(p) })
}

/// The commit HEAD names, read from files (no git): a detached sha, or the ref
/// it points at — loose, or in the COMMON dir's `packed-refs`.
pub fn head_commit(root: &Path) -> Option<String> {
    let gd = git_dir(root)?;
    let head = std::fs::read_to_string(gd.join("HEAD")).ok()?;
    let head = head.trim();
    let Some(r) = head.strip_prefix("ref: ") else {
        return Some(head.to_string());
    };
    let common = std::fs::read_to_string(gd.join("commondir"))
        .ok()
        .map(|c| {
            let p = PathBuf::from(c.trim());
            if p.is_absolute() { p } else { gd.join(p) }
        })
        .unwrap_or_else(|| gd.clone());
    for dir in [&gd, &common] {
        if let Ok(s) = std::fs::read_to_string(dir.join(r)) {
            return Some(s.trim().to_string());
        }
    }
    let packed = std::fs::read_to_string(common.join("packed-refs")).ok()?;
    packed
        .lines()
        .find_map(|l| l.strip_suffix(r).map(|sha| sha.trim().to_string()))
}

/// The current branch name, from HEAD's ref (None when detached).
pub fn head_branch(root: &Path) -> Option<String> {
    let head = std::fs::read_to_string(git_dir(root)?.join("HEAD")).ok()?;
    head.trim().strip_prefix("ref: refs/heads/").map(str::to_string)
}

// ── specs: the names a user can ask for ────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Spec {
    /// `stable` or `latest`.
    Channel(String),
    /// `bleeding-edge` (the source repo) or `bleeding-edge:<worktree dir or branch>`.
    BleedingEdge(Option<String>),
    /// A release tag, `v2026.4`.
    Tag(String),
    /// `commit:<sha prefix>`.
    Commit(String),
    /// `build:<sha8>` or a bare sha8.
    Build(String),
    /// `path:/abs/drop` — a drop file run as-is.
    Path(PathBuf),
}

pub fn parse_spec(s: &str) -> Result<Spec, String> {
    let s = s.trim();
    let hexy = |x: &str| !x.is_empty() && x.bytes().all(|b| b.is_ascii_hexdigit());
    match s {
        "stable" | "latest" => return Ok(Spec::Channel(s.to_string())),
        "bleeding-edge" => return Ok(Spec::BleedingEdge(None)),
        _ => {}
    }
    if let Some(x) = s.strip_prefix("bleeding-edge:") {
        return Ok(Spec::BleedingEdge(Some(x.to_string())));
    }
    if let Some(c) = s.strip_prefix("commit:") {
        return if hexy(c) && c.len() >= 7 {
            Ok(Spec::Commit(c.to_ascii_lowercase()))
        } else {
            Err(format!("`{s}`: a commit is at least 7 hex digits"))
        };
    }
    if let Some(p) = s.strip_prefix("path:") {
        return Ok(Spec::Path(expand_home(p)));
    }
    let id = s.strip_prefix("build:").unwrap_or(s);
    if is_build_id(id) {
        return Ok(Spec::Build(id.to_string()));
    }
    if s.starts_with('v') && s[1..].starts_with(|c: char| c.is_ascii_digit()) {
        return Ok(Spec::Tag(s.to_string()));
    }
    Err(format!(
        "`{s}` is not a build name (stable · latest · bleeding-edge[:DIR|BRANCH] · vX.Y · commit:SHA · build:SHA8 · path:FILE)"
    ))
}

pub fn expand_home(p: &str) -> PathBuf {
    match (p.strip_prefix("~/"), std::env::var("HOME")) {
        (Some(rest), Ok(h)) => PathBuf::from(h).join(rest),
        _ => PathBuf::from(p),
    }
}

// ── declarations, by scan ───────────────────────────────────────────────────

/// A top-level `:KEY "value"` literal in a `.bl` data file, by SCAN — the
/// launcher never evaluates a project's code to decide how to run it (the
/// `declared_daemon_mode` rule). Comment lines are skipped; the key must stand
/// alone (`:bl` does not match `:bl-foo`).
pub fn scan_literal(text: &str, key: &str) -> Option<String> {
    let needle = format!(":{key}");
    for line in text.lines() {
        let code = line.split(';').next().unwrap_or("");
        let mut from = 0;
        while let Some(at) = code[from..].find(&needle) {
            let start = from + at;
            let after = &code[start + needle.len()..];
            let before_ok = start == 0 || code[..start].ends_with(|c: char| c.is_whitespace() || c == '{' || c == ',');
            if before_ok && after.starts_with(|c: char| c.is_whitespace()) {
                let rest = after.trim_start();
                if let Some(v) = rest.strip_prefix('"') {
                    if let Some(end) = v.find('"') {
                        return Some(v[..end].to_string());
                    }
                }
            }
            from = start + needle.len();
        }
    }
    None
}

pub fn config_path() -> PathBuf {
    let base = std::env::var("XDG_CONFIG_HOME")
        .ok()
        .filter(|x| !x.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| expand_home("~/.config"));
    base.join("bl").join("config.bl")
}

pub fn config_literal(key: &str) -> Option<String> {
    scan_literal(&std::fs::read_to_string(config_path()).ok()?, key)
}

/// The beam-lisp checkout builds come from (`:source` in the config).
pub fn source_repo() -> Option<PathBuf> {
    config_literal("source").map(|s| expand_home(&s))
}

/// The nearest beam-lisp SOURCE tree enclosing `cwd`: a git work tree with the
/// boot tier and the checkout launcher. An extracted payload is not one.
pub fn source_tree(cwd: &Path) -> Option<PathBuf> {
    let mut dir = cwd.to_path_buf();
    loop {
        if dir.join("priv/boot/core.bl").is_file() && dir.join("bin/bl").is_file() && dir.join(".git").exists() {
            return Some(std::fs::canonicalize(&dir).unwrap_or(dir));
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// The nearest `env.bl` enclosing `cwd`.
pub fn nearest_env(cwd: &Path) -> Option<PathBuf> {
    let mut dir = cwd.to_path_buf();
    loop {
        let f = dir.join("env.bl");
        if f.is_file() {
            return Some(f);
        }
        if !dir.pop() {
            return None;
        }
    }
}

// ── resolution ──────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Target {
    /// Run stored build `id`.
    Build(String),
    /// Run the tree's own `bin/bl`.
    SourceMode(PathBuf),
    /// Run this drop file as-is.
    Drop(PathBuf),
    /// Nothing in the store answers `spec`; `hint` says how to get it.
    Missing { spec: String, hint: String },
    /// The request itself is wrong (a bad spec).
    Invalid(String),
}

#[derive(Debug)]
pub struct Resolution {
    /// One line per rule consulted, in order — `bl which` prints them.
    pub steps: Vec<String>,
    pub target: Target,
    /// The source tree the answer is about, when there is one.
    pub tree: Option<PathBuf>,
}

/// Which build runs for a command started in `cwd`. First match wins:
///   1. `BL_USE=<spec>`
///   2. a beam-lisp source tree: its build whose stamp matches, else source mode
///   3. the nearest `env.bl`'s `:bl "<spec>"`
///   4. the config's `:default`, else `stable`
pub fn resolve(store: &Store, cwd: &Path) -> Resolution {
    let mut steps = Vec::new();

    if let Some(spec) = std::env::var("BL_USE").ok().filter(|s| !s.trim().is_empty()) {
        steps.push(format!("1 BL_USE={spec}"));
        let target = lookup(store, &spec, &mut steps);
        return Resolution { steps, target, tree: None };
    }
    steps.push("1 BL_USE unset".to_string());

    if let Some(root) = source_tree(cwd) {
        steps.push(format!("2 beam-lisp source tree {}", tildify(&root)));
        let id = tree_id(&root);
        let now = stamp(&root);
        let target = match store.read(&format!("bleeding-edge/{id}")) {
            Some(p) if p.get("stamp") == Some(now.as_str()) && store.has(&p.build) => {
                steps.push(format!("  its last build {} matches this state", p.build));
                Target::Build(p.build)
            }
            Some(p) => {
                steps.push(format!(
                    "  its last build {} is older than this state (edited or checked out since): source mode",
                    p.build
                ));
                Target::SourceMode(root.clone())
            }
            None => {
                steps.push("  no build of this tree yet: source mode".to_string());
                Target::SourceMode(root.clone())
            }
        };
        return Resolution { steps, target, tree: Some(root) };
    }
    steps.push("2 not inside a beam-lisp source tree".to_string());

    if let Some(env) = nearest_env(cwd) {
        match std::fs::read_to_string(&env).ok().and_then(|t| scan_literal(&t, "bl")) {
            Some(spec) => {
                steps.push(format!("3 {} declares :bl \"{spec}\"", tildify(&env)));
                let target = lookup(store, &spec, &mut steps);
                return Resolution { steps, target, tree: None };
            }
            None => steps.push(format!("3 {} declares no :bl", tildify(&env))),
        }
    } else {
        steps.push("3 no env.bl above this directory".to_string());
    }

    let spec = config_literal("default").unwrap_or_else(|| "stable".to_string());
    steps.push(format!("4 default {spec} ({})", tildify(&config_path())));
    let target = lookup(store, &spec, &mut steps);
    Resolution { steps, target, tree: None }
}

/// The build a spec names, from the store alone.
pub fn lookup(store: &Store, spec: &str, steps: &mut Vec<String>) -> Target {
    let parsed = match parse_spec(spec) {
        Ok(s) => s,
        Err(e) => return Target::Invalid(e),
    };
    let missing = |hint: String| Target::Missing { spec: spec.to_string(), hint };
    let found = |p: Option<Pointer>, what: String, steps: &mut Vec<String>| match p {
        Some(p) if store.has(&p.build) => {
            steps.push(format!("  {what} → build {}", p.build));
            Some(Target::Build(p.build))
        }
        Some(p) => {
            steps.push(format!("  {what} → build {}, which is no longer stored", p.build));
            None
        }
        None => None,
    };
    match parsed {
        Spec::Channel(c) => found(store.read(&format!("channels/{c}")), format!("channel {c}"), steps)
            .unwrap_or_else(|| missing(format!("no `{c}` build is stored yet; `bl self-update {c}` gets one"))),
        Spec::Tag(t) => found(store.read(&format!("tags/{t}")), format!("tag {t}"), steps)
            .unwrap_or_else(|| missing(format!("release {t} is not stored; `bl self-update {t}` fetches it"))),
        Spec::Build(id) => {
            if store.has(&id) {
                steps.push(format!("  build {id} is stored"));
                Target::Build(id)
            } else {
                missing(format!("build {id} is not in {}", tildify(&store.root)))
            }
        }
        Spec::Path(p) => {
            if try_read_trailer(&p).is_some() {
                steps.push(format!("  the drop file {}", tildify(&p)));
                Target::Drop(p)
            } else {
                Target::Invalid(format!("{} is not a drop (no DRP1 trailer)", p.display()))
            }
        }
        Spec::Commit(c) => {
            let hits: Vec<(String, Pointer)> = list(store, "sources")
                .into_iter()
                .filter(|(k, _)| k.starts_with(&c) && !k.contains('+'))
                .collect();
            match hits.as_slice() {
                [(k, p)] => found(Some(p.clone()), format!("commit {}", &k[..12.min(k.len())]), steps)
                    .unwrap_or_else(|| missing(format!("commit {c} was built, but its build is gone; `bl self-update commit:{c}` rebuilds it"))),
                [] => missing(format!("commit {c} has no build yet; `bl self-update commit:{c}` builds it")),
                _ => Target::Invalid(format!("commit:{c} matches {} builds; give more digits", hits.len())),
            }
        }
        Spec::BleedingEdge(which) => {
            let tree = match which.as_deref() {
                None => source_repo(),
                // A PATH is spelled as one (`/…`, `~/…`, `./…`, `../…`) or names a
                // directory that exists; anything else is a branch, and branch
                // names carry slashes too (`names/portless`).
                Some(x) if x.starts_with(['/', '~', '.']) || Path::new(x).is_dir() => {
                    Some(std::fs::canonicalize(expand_home(x)).unwrap_or_else(|_| expand_home(x)))
                }
                Some(branch) => {
                    let hit = list(store, "bleeding-edge").into_iter().find(|(_, p)| p.get("branch") == Some(branch));
                    return hit
                        .and_then(|(_, p)| found(Some(p), format!("bleeding-edge of branch {branch}"), steps))
                        .unwrap_or_else(|| missing(format!("no worktree on branch {branch} has been built")));
                }
            };
            let Some(tree) = tree else {
                return missing("no `:source` checkout in the config to take bleeding-edge from".to_string());
            };
            found(
                store.read(&format!("bleeding-edge/{}", tree_id(&tree))),
                format!("bleeding-edge of {}", tildify(&tree)),
                steps,
            )
            .unwrap_or_else(|| missing(format!("{} has not been built yet; commit there, or `bl self-update`", tildify(&tree))))
        }
    }
}

/// Every pointer in a store directory, by file name.
pub fn list(store: &Store, dir: &str) -> Vec<(String, Pointer)> {
    let Ok(rd) = std::fs::read_dir(store.meta().join(dir)) else { return vec![] };
    let mut out: Vec<(String, Pointer)> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.contains(".tmp-") {
                return None;
            }
            let p = Pointer::parse(&std::fs::read_to_string(e.path()).ok()?)?;
            Some((name, p))
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

pub fn tildify(p: &Path) -> String {
    let s = p.display().to_string();
    match std::env::var("HOME") {
        Ok(h) if !h.is_empty() && s.starts_with(&format!("{h}/")) => format!("~{}", &s[h.len()..]),
        _ => s,
    }
}

/// Read the `DRP1` trailer (56 bytes at EOF) of the file at `path`, or None
/// when it has none — which is how the PATH launcher knows it IS the launcher.
/// O(1) on every call: the payload is hashed only when it is extracted
/// (`verify_and_extract_from`); re-hashing 100 MB per call was the launcher's
/// latency floor (~0.3 s).
pub fn try_read_trailer(path: &Path) -> Option<Trailer> {
    use std::io::{Read, Seek, SeekFrom};
    let mut f = std::fs::File::open(path).ok()?;
    let flen = f.metadata().ok()?.len();
    if flen < TRAILER_LEN as u64 {
        return None;
    }
    f.seek(SeekFrom::End(-(TRAILER_LEN as i64))).ok()?;
    let mut buf = vec![0u8; TRAILER_LEN];
    f.read_exact(&mut buf).ok()?;
    parse_trailer(&buf)
}

pub fn sha8_of(t: &Trailer) -> String {
    hex(&t.sha256)[..8].to_string()
}

/// The value of `:KEY "…"` in a payload's `BUILD_INFO.bl` (a printed map).
pub fn build_info_field(payload: &Path, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(payload.join("BUILD_INFO.bl")).ok()?;
    let needle = format!(":{key} \"");
    let at = text.find(&needle)? + needle.len();
    let end = text[at..].find('"')?;
    Some(text[at..at + end].to_string())
}

#[cfg(test)]
mod store_tests {
    use super::*;

    fn scratch(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("drop-store-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn inputs_match_provenance() {
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../priv/build/provenance.bl");
        let text = std::fs::read_to_string(src).expect("provenance.bl beside the crate");
        let start = text.find("(def INPUTS").unwrap();
        let open = start + text[start..].find('[').unwrap();
        let close = open + text[open..].find(']').unwrap();
        let listed: Vec<&str> = text[open + 1..close].split('"').skip(1).step_by(2).collect();
        assert_eq!(listed, BUILD_INPUTS, "store.rs BUILD_INPUTS and provenance/INPUTS must agree");
    }

    #[test]
    fn pointers_round_trip_and_reject_non_builds() {
        let p = Pointer::new("7154e76a").with("stamp", "abc").with("branch", "main").with("empty", "");
        assert_eq!(Pointer::parse(&p.render()), Some(p.clone()));
        assert_eq!(p.get("branch"), Some("main"));
        assert_eq!(p.get("empty"), None);
        assert_eq!(Pointer::parse("build ../../etc\n"), None);
        assert_eq!(Pointer::parse("nothing here"), None);
    }

    #[test]
    fn a_slashed_name_is_a_branch_unless_spelled_as_a_path() {
        with_store("branchpath", |store, d| {
            let wt = d.join("wt");
            std::fs::create_dir_all(&wt).unwrap();
            let wt = std::fs::canonicalize(&wt).unwrap();
            stored(store, "abababab");
            store.write(&format!("bleeding-edge/{}", tree_id(&wt)), &Pointer::new("abababab")).unwrap();
            let mut s = vec![];
            assert_eq!(lookup(store, &format!("bleeding-edge:{}", wt.display()), &mut s), Target::Build("abababab".into()));
            assert!(matches!(lookup(store, "bleeding-edge:no/such-branch", &mut s), Target::Missing { .. }));
        });
    }

    #[test]
    fn specs_parse() {
        assert_eq!(parse_spec("stable"), Ok(Spec::Channel("stable".into())));
        assert_eq!(parse_spec("latest"), Ok(Spec::Channel("latest".into())));
        assert_eq!(parse_spec("bleeding-edge"), Ok(Spec::BleedingEdge(None)));
        assert_eq!(parse_spec("bleeding-edge:names/portless"), Ok(Spec::BleedingEdge(Some("names/portless".into()))));
        assert_eq!(parse_spec("v2026.4"), Ok(Spec::Tag("v2026.4".into())));
        assert_eq!(parse_spec("commit:1CF72D26"), Ok(Spec::Commit("1cf72d26".into())));
        assert!(parse_spec("commit:1cf").is_err());
        assert_eq!(parse_spec("7154e76a"), Ok(Spec::Build("7154e76a".into())));
        assert_eq!(parse_spec("build:7154e76a"), Ok(Spec::Build("7154e76a".into())));
        assert_eq!(parse_spec("path:/tmp/x"), Ok(Spec::Path("/tmp/x".into())));
        assert!(parse_spec("nightly").is_err());
    }

    #[test]
    fn scan_reads_only_a_standalone_key() {
        let text = ";; :bl \"latest\" in a comment does not count\n{:name \"x\"\n :bl-extra \"no\"\n :bl \"commit:1cf72d26\"}";
        assert_eq!(scan_literal(text, "bl"), Some("commit:1cf72d26".into()));
        assert_eq!(scan_literal("{:name \"x\"}", "bl"), None);
        assert_eq!(scan_literal("{:bl \"latest\"}", "bl"), Some("latest".into()));
    }

    fn fake_tree(dir: &Path) {
        std::fs::create_dir_all(dir.join("priv/boot")).unwrap();
        std::fs::create_dir_all(dir.join("bin")).unwrap();
        std::fs::create_dir_all(dir.join(".git/refs/heads")).unwrap();
        std::fs::write(dir.join("priv/boot/core.bl"), "core").unwrap();
        std::fs::write(dir.join("bin/bl"), "#!/bin/sh\n").unwrap();
        std::fs::write(dir.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        std::fs::write(dir.join(".git/refs/heads/main"), "1111111111111111111111111111111111111111\n").unwrap();
    }

    #[test]
    fn the_stamp_moves_with_inputs_and_head_only() {
        let d = scratch("stamp");
        fake_tree(&d);
        let a = stamp(&d);
        assert_eq!(a, stamp(&d), "a stamp is a pure function of the tree");

        std::fs::write(d.join("notes.org"), "not an input").unwrap();
        std::fs::create_dir_all(d.join("priv/native")).unwrap();
        std::fs::write(d.join("priv/native/x.so"), "a build output").unwrap();
        assert_eq!(a, stamp(&d), "non-inputs and build outputs do not move it");

        std::fs::write(d.join(".git/refs/heads/main"), "2222222222222222222222222222222222222222\n").unwrap();
        let b = stamp(&d);
        assert_ne!(a, b, "a new commit moves it");

        std::thread::sleep(std::time::Duration::from_millis(10));
        std::fs::write(d.join("priv/boot/core.bl"), "core, edited").unwrap();
        assert_ne!(b, stamp(&d), "an edited input moves it");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn head_reads_worktrees_and_packed_refs() {
        let d = scratch("head");
        let common = d.join("repo/.git");
        std::fs::create_dir_all(common.join("worktrees/wt")).unwrap();
        std::fs::write(common.join("packed-refs"), "# pack-refs\n3333333333333333333333333333333333333333 refs/heads/feature\n").unwrap();
        std::fs::write(common.join("worktrees/wt/HEAD"), "ref: refs/heads/feature\n").unwrap();
        std::fs::write(common.join("worktrees/wt/commondir"), "../..\n").unwrap();
        let wt = d.join("wt");
        std::fs::create_dir_all(&wt).unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", common.join("worktrees/wt").display())).unwrap();
        assert_eq!(head_commit(&wt).as_deref(), Some("3333333333333333333333333333333333333333"));
        assert_eq!(head_branch(&wt).as_deref(), Some("feature"));
        let _ = std::fs::remove_dir_all(&d);
    }

    fn with_store<T>(tag: &str, f: impl FnOnce(&Store, &Path) -> T) -> T {
        let d = scratch(tag);
        let store = Store { root: d.join("data") };
        let r = f(&store, &d);
        let _ = std::fs::remove_dir_all(&d);
        r
    }

    fn stored(store: &Store, id: &str) {
        std::fs::create_dir_all(store.payload(id).join("bin")).unwrap();
    }

    #[test]
    fn lookup_answers_from_the_store_alone() {
        with_store("lookup", |store, _| {
            let mut s = vec![];
            assert!(matches!(lookup(store, "stable", &mut s), Target::Missing { .. }));
            stored(store, "aaaaaaaa");
            store.write("channels/stable", &Pointer::new("aaaaaaaa")).unwrap();
            assert_eq!(lookup(store, "stable", &mut s), Target::Build("aaaaaaaa".into()));

            store.write("sources/1cf72d26294b95444125fbea569a592f1f37c1af", &Pointer::new("aaaaaaaa")).unwrap();
            store.write("sources/1cf72d26294b95444125fbea569a592f1f37c1af+ac81415ef986", &Pointer::new("bbbbbbbb")).unwrap();
            assert_eq!(lookup(store, "commit:1cf72d26", &mut s), Target::Build("aaaaaaaa".into()), "a commit is its CLEAN build");

            store.write("channels/latest", &Pointer::new("cccccccc")).unwrap();
            assert!(matches!(lookup(store, "latest", &mut s), Target::Missing { .. }), "a pointer to a build that is gone is missing");

            stored(store, "dddddddd");
            store.write("bleeding-edge/0000", &Pointer::new("dddddddd").with("branch", "names/portless")).unwrap();
            assert_eq!(lookup(store, "bleeding-edge:names/portless", &mut s), Target::Build("dddddddd".into()));
            assert!(matches!(lookup(store, "nonsense", &mut s), Target::Invalid(_)));
        });
    }

    #[test]
    fn a_source_tree_runs_its_build_only_while_the_stamp_matches() {
        with_store("tree", |store, d| {
            let tree = d.join("wt");
            fake_tree(&tree);
            let tree = std::fs::canonicalize(&tree).unwrap();
            let sub = tree.join("priv/boot");
            assert_eq!(resolve(store, &sub).target, Target::SourceMode(tree.clone()), "never built: source mode");

            stored(store, "eeeeeeee");
            let key = format!("bleeding-edge/{}", tree_id(&tree));
            store.write(&key, &Pointer::new("eeeeeeee").with("stamp", &stamp(&tree))).unwrap();
            assert_eq!(resolve(store, &sub).target, Target::Build("eeeeeeee".into()), "built from this state: that build");

            std::thread::sleep(std::time::Duration::from_millis(10));
            std::fs::write(tree.join("priv/boot/core.bl"), "edited").unwrap();
            assert_eq!(resolve(store, &sub).target, Target::SourceMode(tree.clone()), "edited since: source mode");
        });
    }

    #[test]
    fn a_project_declares_its_build_and_everything_else_is_the_default() {
        with_store("project", |store, d| {
            let proj = d.join("proj");
            std::fs::create_dir_all(proj.join("src")).unwrap();
            stored(store, "aaaaaaaa");
            stored(store, "ffffffff");
            store.write("channels/stable", &Pointer::new("aaaaaaaa")).unwrap();
            store.write("channels/latest", &Pointer::new("ffffffff")).unwrap();

            std::fs::write(proj.join("env.bl"), "{:name \"p\"}").unwrap();
            assert_eq!(resolve(store, &proj.join("src")).target, Target::Build("aaaaaaaa".into()), "no :bl → stable");

            std::fs::write(proj.join("env.bl"), "{:name \"p\" :bl \"latest\"}").unwrap();
            assert_eq!(resolve(store, &proj.join("src")).target, Target::Build("ffffffff".into()), ":bl latest");
        });
    }
}
