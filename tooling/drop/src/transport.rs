// transport.rs — how a `bl` command reaches a VM: cold, warm-attach, warm-start.
// (included via include! into launcher.rs — no //! inner docs allowed here)
//
// The decision is PURE and DECLARED: a flag on the command line beats the
// tree's own `env.bl`, which beats the machine's `~/.config/bl/config.bl`,
// which beats DEFAULT_TRANSPORT. Nothing here reads an environment variable —
// the transport is a property of the invocation and the tree, not of whatever
// shell happened to export.
//
// `Path`/`PathBuf` come from daemon.rs, included before this file.
//
// VM SHARING follows the same declared rule: `--shared`/`--own`, then the
// tree's `:vm` declaration, then own. It chooses which VM answers for the
// project (`daemon.rs::endpoint_key`), never whether one is started.
//
// `warm` is the declared spelling. The daemon that answers is the release's
// long-lived VM (`bl realm start`); a cold path boots a fresh one per command.

/// Run this command in a fresh VM; never attach to or start a warm one.
pub const COLD_FLAG: &str = "--cold";
/// Attach to the warm VM, starting one (detached) if none is running.
pub const WARM_FLAG: &str = "--warm";
/// The tree root to key the warm VM on (VALUED: it takes the next token).
pub const ROOT_FLAG: &str = "--root";
/// Boolean; only meaningful to `realm start` (it becomes the VM in the foreground).
pub const FOREGROUND_FLAG: &str = "--foreground";
/// The VM's log file, handed to `realm start` so `bl vm logs` reads the very
/// file the VM writes (VALUED: it takes the next token).
pub const LOG_FLAG: &str = "--log";
/// How long an idle warm VM lingers before it exits (VALUED).
pub const IDLE_FLAG: &str = "--idle";
/// How many trailing log lines a reader shows (VALUED).
pub const LINES_FLAG: &str = "--lines";

/// How a command reaches a VM.
#[derive(PartialEq, Eq, Debug, Clone, Copy)]
pub enum Transport {
    /// A fresh VM for this command; never attach to or start a warm one.
    Cold,
    /// Use the warm VM if one is running; never start one.
    Attach,
    /// Use the warm VM, and start one (detached) if none is running.
    ///
    /// Starting NEVER blocks the command that triggered it: the VM comes up in
    /// the background and THIS command runs cold, immediately. A boot the user
    /// did not ask to wait for must not slow the command that hinted at it, and
    /// a start that fails costs this command nothing.
    Start,
}

/// The transport when nothing says otherwise.
///
/// ATTACH, not `Start`, today: a warm VM belongs to ONE tree, so `Start` would
/// conjure one VM PER DIRECTORY — more than a user asked for — until
/// one-VM-per-user lands. Attach keeps the launcher's promise narrow: a warm VM
/// is used when it is there, never started behind the user's back. A command
/// still runs fine when none is running (it goes cold); `--warm` or a tree's
/// `:warm "start"` asks for a warm VM explicitly. Flipping this default later
/// is this ONE line.
pub const DEFAULT_TRANSPORT: Transport = Transport::Attach;

/// The declaration key: `:warm "…"` in `env.bl` or the config, read by
/// `scan_literal` — SCANNED, never evaluated.
pub const WARM_KEY: &str = "warm";

/// The accepted `:warm` spellings and the transport each names. A value not in
/// this table is ignored: prose must not become policy.
pub const WARM_SPELLINGS: &[(&str, Transport)] = &[
    ("off", Transport::Cold),
    ("attach", Transport::Attach),
    ("start", Transport::Start),
];

/// The declaration key for VM sharing: `:vm "…"` in `env.bl`, read by
/// `scan_literal` — SCANNED, never evaluated.
pub const VM_KEY: &str = "vm";

/// The accepted `:vm` spellings and whether each asks for a SHARED VM. A value
/// not in this table is ignored: prose must not become policy.
pub const VM_SPELLINGS: &[(&str, bool)] = &[("own", false), ("shared", true)];

/// Boolean flag; force a shared VM for this invocation.
pub const SHARED_FLAG: &str = "--shared";
/// Boolean flag; force this project's own VM. Beats `SHARED_FLAG`.
pub const OWN_FLAG: &str = "--own";

/// Whether the invocation asks for a SHARED VM: `--shared`/`--own` first, then
/// `env_bl_text`'s `:vm` declaration, then the default (own). The flags are
/// BOOLEAN (they take no value), and `--own` wins when both are given: an
/// explicit request for isolation is the safe choice, and an extra flag must
/// never silently share a VM. `--` ends the scan (`flag_present`).
pub fn shared_for(argv: &[String], env_bl_text: Option<&str>) -> bool {
    if flag_present(argv, OWN_FLAG) {
        return false;
    }
    if flag_present(argv, SHARED_FLAG) {
        return true;
    }
    env_bl_text
        .and_then(|t| scan_literal(t, VM_KEY))
        .and_then(|v| vm_spelling(&v))
        .unwrap_or(false)
}

fn vm_spelling(v: &str) -> Option<bool> {
    VM_SPELLINGS.iter().find(|(s, _)| *s == v).map(|(_, b)| *b)
}

/// Is `flag` present in `argv` before a literal `--`? Everything after `--`
/// belongs to the program being run, not to `bl`.
pub fn flag_present(argv: &[String], flag: &str) -> bool {
    for a in argv {
        if a == "--" {
            return false;
        }
        if a == flag {
            return true;
        }
    }
    false
}

/// The `--root DIR` override, when `DIR` is present before `--`. A trailing
/// `--root` with no value is not an override (the release reports the usage
/// error). Returned as written; the caller canonicalizes.
pub fn root_override(argv: &[String]) -> Option<PathBuf> {
    for (i, a) in argv.iter().enumerate() {
        if a == "--" {
            return None;
        }
        if a == ROOT_FLAG {
            return argv.get(i + 1).filter(|v| !v.is_empty()).map(PathBuf::from);
        }
    }
    None
}

/// The WHOLE precedence rule, pure. First match wins:
///   1. `--cold` → Cold, `--warm` → Start. A flag beats every declaration, and
///      `--cold` is checked first so it wins when both appear (the safer,
///      explicit-debug choice).
///   2. `tree_text` (the tree's `env.bl`) `:warm`.
///   3. `config_text` (`~/.config/bl/config.bl`) `:warm`.
///   4. DEFAULT_TRANSPORT.
///
/// An unrecognised `:warm` value is skipped, so the config below it still gets
/// its say.
pub fn transport_from(argv: &[String], tree_text: Option<&str>, config_text: Option<&str>) -> Transport {
    if flag_present(argv, COLD_FLAG) {
        return Transport::Cold;
    }
    if flag_present(argv, WARM_FLAG) {
        return Transport::Start;
    }
    for text in [tree_text, config_text] {
        let declared = text.and_then(|t| scan_literal(t, WARM_KEY)).and_then(|v| warm_spelling(&v));
        if let Some(t) = declared {
            return t;
        }
    }
    DEFAULT_TRANSPORT
}

/// The transport for `root` under `argv`: the thin reader that loads the tree's
/// `env.bl` and the config, then calls `transport_from`.
pub fn transport(root: &Path, argv: &[String]) -> Transport {
    let tree_text = std::fs::read_to_string(root.join(PROJECT_FILE)).ok();
    let config_text = std::fs::read_to_string(config_path()).ok();
    transport_from(argv, tree_text.as_deref(), config_text.as_deref())
}

fn warm_spelling(v: &str) -> Option<Transport> {
    WARM_SPELLINGS.iter().find(|(s, _)| *s == v).map(|(_, t)| *t)
}

// ── verb recognition ────────────────────────────────────────────────────────

/// The verb that starts a warm VM in the foreground: `realm start`.
pub const REALM_START: &[&str] = &["realm", "start"];
/// The verb that stops the warm VM: `realm stop`.
pub const REALM_STOP: &[&str] = &["realm", "stop"];

/// Whether `argv` is a request for the launcher to start a warm VM: the verb
/// sequence `realm start`, with the global flags before the verb skipped. The
/// old `daemon start` is NOT recognised here — the launcher knows only the new
/// spelling, so it is just an unknown verb. `--foreground` is NOT a request:
/// that invocation must reach the VM, which becomes the warm VM in the
/// foreground.
pub fn start_requested(argv: &[String]) -> bool {
    if flag_present(argv, FOREGROUND_FLAG) {
        return false;
    }
    let Some(i) = verb_index(argv) else {
        return false;
    };
    REALM_START.iter().enumerate().all(|(k, w)| argv.get(i + k).map(String::as_str) == Some(*w))
}

/// Verbs the launcher never attaches for: `realm` and `vm` manage warm VMs
/// themselves, so they must run in a FRESH process — a `bl vm stop X` running
/// INSIDE warm VM X could not stop X (the command would cut itself off). They
/// never attach to a warm VM.
pub const LIFECYCLE_VERBS: &[&str] = &["realm", "vm"];

/// The release argv that starts a warm VM in the foreground, with its log at
/// `log`. A SHARED VM boots rootless (`--shared`, NO `--root`): it serves every
/// shared project of the build and resolves the realm per request from the
/// frame cwd. An own VM is handed its root. The log path is an ARGUMENT so the
/// VM knows where to write and `bl vm logs` reads the very file the launcher's
/// child writes.
pub fn warm_start_argv(root: &Path, shared: bool, log: &Path) -> Vec<String> {
    let mut a = words(REALM_START);
    a.push(FOREGROUND_FLAG.to_string());
    if shared {
        a.push(SHARED_FLAG.to_string());
    } else {
        a.push(ROOT_FLAG.to_string());
        a.push(root.to_string_lossy().into_owned());
    }
    a.push(LOG_FLAG.to_string());
    a.push(log.to_string_lossy().into_owned());
    a
}

/// The release argv that stops the warm VM for `root`.
pub fn warm_stop_argv(root: &Path) -> Vec<String> {
    let mut a = words(REALM_STOP);
    a.push(ROOT_FLAG.to_string());
    a.push(root.to_string_lossy().into_owned());
    a
}

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

#[cfg(test)]
mod transport_tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn a(args: &[&str]) -> Vec<String> {
        args.iter().map(|s| s.to_string()).collect()
    }

    /// A flag beats both declarations, and `--cold` beats `--warm`.
    #[test]
    fn a_flag_beats_every_declaration_and_cold_beats_warm() {
        let tree = ":warm \"attach\"";
        let config = ":warm \"attach\"";
        assert_eq!(transport_from(&a(&["--cold"]), Some(tree), Some(config)), Transport::Cold);
        assert_eq!(transport_from(&a(&["--warm"]), Some(tree), Some(config)), Transport::Start);
        assert_eq!(transport_from(&a(&["--warm", "--cold"]), None, None), Transport::Cold);
        assert_eq!(transport_from(&a(&["--cold", "--warm"]), None, None), Transport::Cold);
    }

    /// env.bl beats the config; the config beats the default.
    #[test]
    fn the_trees_declaration_beats_the_configs_which_beats_the_default() {
        assert_eq!(transport_from(&[], Some(":warm \"off\""), Some(":warm \"start\"")), Transport::Cold);
        assert_eq!(transport_from(&[], Some(":warm \"attach\""), Some(":warm \"off\"")), Transport::Attach);
        assert_eq!(transport_from(&[], Some(""), Some(":warm \"start\"")), Transport::Start);
        assert_eq!(transport_from(&[], None, Some(":warm \"off\"")), Transport::Cold);
        assert_eq!(transport_from(&[], None, None), DEFAULT_TRANSPORT);
        assert_eq!(DEFAULT_TRANSPORT, Transport::Attach);
    }

    /// Prose must not become policy: an unknown value is ignored, not obeyed.
    #[test]
    fn an_unrecognised_value_is_ignored() {
        assert_eq!(
            transport_from(&[], Some(":warm \"whenever\""), Some(":warm \"off\"")),
            Transport::Cold,
            "an unknown tree value falls through to the config"
        );
        assert_eq!(transport_from(&[], Some(":warm \"whenever\""), None), DEFAULT_TRANSPORT);
        assert_eq!(
            transport_from(&[], Some(";; :warm \"off\" in a comment\n{:name \"x\"}"), None),
            DEFAULT_TRANSPORT,
            "a comment is not a declaration"
        );
    }

    /// `--` ends the launcher's flags: what follows is the program's argv.
    #[test]
    fn flags_after_a_literal_double_dash_belong_to_the_program() {
        assert!(!flag_present(&a(&["run", "--", "--cold"]), COLD_FLAG));
        assert!(flag_present(&a(&["--cold", "run"]), COLD_FLAG));
        assert_eq!(root_override(&a(&["run", "--", "--root", "/x"])), None);
        assert_eq!(transport_from(&a(&["run", "--", "--cold"]), None, None), DEFAULT_TRANSPORT);
    }

    /// `--root DIR` takes the next token; a trailing `--root` has none.
    #[test]
    fn root_is_a_valued_flag() {
        assert_eq!(root_override(&a(&["--root", "/x", "run"])), Some(PathBuf::from("/x")));
        assert_eq!(root_override(&a(&["run", "--root", "/y"])), Some(PathBuf::from("/y")));
        assert_eq!(root_override(&a(&["--root"])), None, "a trailing --root has no value");
        assert_eq!(root_override(&a(&["--root", ""])), None, "an empty value is no value");
    }

    /// The valued flag is skipped when finding the verb, so `--root DIR` cannot
    /// be mistaken for one.
    #[test]
    fn the_root_flag_is_skipped_by_verb_index() {
        assert_eq!(verb_index(&a(&["--root", "/x", "run", "f"])), Some(2));
        assert_eq!(verb_index(&a(&["--root"])), None);
    }

    /// `realm start` is the request; a global flag before the verb is skipped.
    #[test]
    fn realm_start_is_a_start_request() {
        assert!(start_requested(&a(&["realm", "start"])));
        assert!(
            start_requested(&a(&["--json", "realm", "start"])),
            "a global flag before the verb is skipped"
        );
        assert!(start_requested(&a(&["--root", "/x", "realm", "start"])), "--root takes a value");
        assert!(start_requested(&a(&["realm", "start", "--json"])), "a trailing flag does not hide the request");
    }

    #[test]
    fn realm_start_foreground_is_not_a_start_request() {
        assert!(!start_requested(&a(&["realm", "start", "--foreground"])));
    }

    /// The old spelling is gone: to the launcher it is just an unknown verb.
    #[test]
    fn daemon_start_is_not_a_start_request() {
        assert!(!start_requested(&a(&["daemon", "start"])));
    }

    #[test]
    fn argv_that_is_not_the_verb_is_not_a_request() {
        assert!(!start_requested(&a(&["realm", "stop"])));
        assert!(!start_requested(&a(&["realm"])));
        assert!(!start_requested(&a(&["realm", "started"])));
        assert!(!start_requested(&a(&["run", "realm", "start"])), "an argument is not a verb");
    }

    #[test]
    fn lifecycle_verbs_are_realm_and_vm() {
        assert_eq!(LIFECYCLE_VERBS, &["realm", "vm"]);
        for v in ["test", "run", "eval"] {
            assert!(!LIFECYCLE_VERBS.contains(&v), "{v} attaches to a warm VM");
        }
    }

    /// Warm start/stop hand the release named arguments, not string soup: an own
    /// VM is given its root, a shared VM boots rootless with `--shared`.
    #[test]
    fn the_warm_argv_lists_name_realm() {
        let root = Path::new("/tree");
        let log = Path::new("/state/beam-lisp/logs/tree-abc.log");
        assert_eq!(
            warm_start_argv(root, false, log),
            a(&["realm", "start", "--foreground", "--root", "/tree", "--log", "/state/beam-lisp/logs/tree-abc.log"])
        );
        assert_eq!(
            warm_start_argv(root, true, log),
            a(&["realm", "start", "--foreground", "--shared", "--log", "/state/beam-lisp/logs/tree-abc.log"]),
            "a shared VM boots rootless: no --root"
        );
        assert_eq!(warm_stop_argv(root), a(&["realm", "stop", "--root", "/tree"]));
    }

    /// Sharing is a DECLARATION a flag may override, never a default: no flag
    /// and no key means own, a spelling outside the table is ignored, and `--own`
    /// wins when both flags are given. `--` ends the scan.
    #[test]
    fn sharing_is_flagged_declared_then_owned() {
        let shared = Some(r#"{:vm "shared"}"#);
        let own = Some(r#"{:vm "own"}"#);
        let bogus = Some(r#"{:vm "bogus"}"#);
        assert!(!shared_for(&a(&[]), None), "the default is own");
        assert!(shared_for(&a(&[]), shared));
        assert!(!shared_for(&a(&[]), own));
        assert!(!shared_for(&a(&[]), bogus), "an unknown spelling is ignored");
        assert!(shared_for(&a(&["--shared"]), own), "the flag beats the declaration");
        assert!(!shared_for(&a(&["--own"]), shared));
        assert!(!shared_for(&a(&["--shared", "--own"]), None), "own wins when both are given");
        assert!(!shared_for(&a(&["--own", "--shared"]), None));
        assert!(!shared_for(&a(&["run", "--", "--shared"]), None), "-- ends the scan");
    }

    #[test]
    fn the_sharing_flags_and_key_are_one_spelling_each() {
        assert_eq!(SHARED_FLAG, "--shared");
        assert_eq!(OWN_FLAG, "--own");
        assert_eq!(VM_KEY, "vm");
    }

    /// The log/idle/lines flags take a value; one spelling each.
    #[test]
    fn the_log_and_reader_flags_are_valued() {
        assert_eq!(LOG_FLAG, "--log");
        assert_eq!(IDLE_FLAG, "--idle");
        assert_eq!(LINES_FLAG, "--lines");
    }
}
