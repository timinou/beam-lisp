//! Tracked MVCC logical checkpoints. Capture performs no destination I/O; a
//! coordinator can capture several stores in one declared-owner boundary and
//! export after releasing it. The exact source claim stays pinned, never reopened.
use super::{err, DbHandle, StoreClaim};
use fjall::{Config, Keyspace, PartitionCreateOptions, PartitionHandle, PersistMode, Snapshot};
use rustler::{Atom, Encoder, NifResult, Resource, ResourceArc, Term, LocalPid, OwnedEnv};
use std::fs::{self, File};
use std::io::Write;
use std::ops::Bound::{Excluded, Unbounded};
use std::path::{Path, PathBuf};
use std::sync::{atomic::{AtomicBool, AtomicU64, Ordering}, Arc, Mutex};

mod atoms { rustler::atoms! { released, aborted, published, accepted, error } }
static NEXT_STAGE: AtomicU64 = AtomicU64::new(1);

struct Capture {
    // Snapshot must drop before the engine's claim.
    snapshot: Snapshot,
    _source: Arc<StoreClaim>,
    path: PathBuf,
    sequence: u64,
}
struct Cursor(Mutex<Option<Arc<Capture>>>);
#[rustler::resource_impl]
impl Resource for Cursor {}
impl Drop for Cursor {
    fn drop(&mut self) {
        if let Some(capture) = self.0.get_mut().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = std::thread::Builder::new().name("datom-snapshot-cleanup".into()).spawn(move || drop(capture));
        }
    }
}

struct Engine { keyspace: Keyspace, datoms: PartitionHandle }
struct Export {
    capture: Option<Arc<Capture>>,
    source: PathBuf,
    sequence: u64,
    // Engine drops before flock and temporary directory removal.
    engine: Option<Engine>,
    flock: Option<File>,
    stage: PathBuf,
    destination: PathBuf,
    last: Option<Vec<u8>>,
    entries: u64,
    bytes: u64,
    exhausted: bool,
    published: bool,
    stable: bool,
}
impl Drop for Export {
    fn drop(&mut self) {
        self.engine.take();
        self.flock.take();
        if !self.published { let _ = fs::remove_dir_all(&self.stage); }
    }
}
struct Artifact(Mutex<Option<Export>>, AtomicBool);
#[rustler::resource_impl]
impl Resource for Artifact {}
impl Drop for Artifact {
    fn drop(&mut self) {
        // Resource GC may run on an ordinary BEAM scheduler. Engine shutdown
        // and filesystem cleanup must not block it.
        if let Some(export) = self.0.get_mut().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = std::thread::Builder::new().name("datom-checkpoint-cleanup".into())
                .spawn(move || drop(export));
        }
    }
}

fn capture(source: Arc<StoreClaim>, path: PathBuf) -> Result<Arc<Capture>, String> {
    let _writer = source.engine.lock.lock().map_err(|e| e.to_string())?;
    let sequence = source.engine.keyspace.instant();
    Ok(Arc::new(Capture { snapshot: source.engine.datoms.snapshot_at(sequence),
        _source: source.clone(), path, sequence }))
}
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_checkpoint_capture(source: ResourceArc<DbHandle>) -> NifResult<ResourceArc<Cursor>> {
    let capture = capture(source._claim.clone(), source.path.clone()).map_err(err)?;
    Ok(ResourceArc::new(Cursor(Mutex::new(Some(capture)))))
}
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_checkpoint_release(cursor: ResourceArc<Cursor>) -> NifResult<Atom> {
    cursor.0.lock().map_err(err)?.take();
    Ok(atoms::released())
}

fn begin(capture: Arc<Capture>, destination: &Path) -> Result<Export, String> {
    let leaf = destination.file_name().ok_or("checkpoint destination needs a filename")?;
    if leaf == "." || leaf == ".." { return Err("invalid checkpoint destination".into()); }
    let parent = fs::canonicalize(destination.parent().unwrap_or_else(|| Path::new(".")))
        .map_err(|e| e.to_string())?;
    let destination = parent.join(leaf);
    if destination.symlink_metadata().is_ok() { return Err("checkpoint destination already exists".into()); }
    let source = &capture.path;
    if destination.starts_with(source) || source.starts_with(&destination) {
        return Err("checkpoint destination overlaps source".into());
    }
    let stage = loop {
        let path = parent.join(format!(".datom-checkpoint-{}-{}", std::process::id(), NEXT_STAGE.fetch_add(1, Ordering::Relaxed)));
        match fs::create_dir(&path) {
            Ok(()) => break path,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e.to_string()),
        }
    };
    let opened = (|| {
        let flock = File::open(&stage).map_err(|e| e.to_string())?;
        flock.try_lock().map_err(|e| e.to_string())?;
        let keyspace = Config::new(&stage).open().map_err(|e| e.to_string())?;
        let datoms = keyspace.open_partition("datoms", PartitionCreateOptions::default()).map_err(|e| e.to_string())?;
        Ok((Engine { keyspace, datoms }, flock))
    })();
    match opened {
        Ok((engine, flock)) => Ok(Export { source: capture.path.clone(), sequence: capture.sequence, capture: Some(capture), engine: Some(engine), flock: Some(flock), stage, destination,
            last: None, entries: 0, bytes: 0, exhausted: false, published: false, stable: false }),
        Err(e) => { let _ = fs::remove_dir_all(stage); Err(e) }
    }
}
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_checkpoint_begin(cursor: ResourceArc<Cursor>, destination: String) -> NifResult<ResourceArc<Artifact>> {
    let capture = cursor.0.lock().map_err(err)?.as_ref().cloned().ok_or_else(|| err("checkpoint cursor released"))?;
    Ok(ResourceArc::new(Artifact(Mutex::new(Some(begin(capture, Path::new(&destination)).map_err(err)?)), AtomicBool::new(false))))
}

fn step(export: &mut Export, rows: usize, max_bytes: usize) -> Result<(bool, u64, u64, u64), String> {
    if rows == 0 || rows > 65_536 || max_bytes == 0 || max_bytes > 64 * 1024 * 1024 {
        return Err("invalid checkpoint chunk bound".into());
    }
    let engine = export.engine.as_ref().ok_or("checkpoint no longer accepts chunks")?;
    if export.exhausted { return Ok((true, 0, export.entries, 0)); }
    let mut iter = export.capture.as_ref().ok_or("checkpoint cursor released")?.snapshot.range::<Vec<u8>, _>(match &export.last {
        Some(last) => (Excluded(last.clone()), Unbounded), None => (Unbounded, Unbounded),
    });
    let mut batch = engine.keyspace.batch();
    let mut n = 0_u64;
    let mut bytes = 0_usize;
    let mut last = None;
    let mut exhausted = false;
    while n < rows as u64 {
        match iter.next() {
            None => { exhausted = true; break; }
            Some(Err(e)) => return Err(e.to_string()),
            Some(Ok((key, value))) => {
                let size = key.len().checked_add(value.len()).ok_or("checkpoint entry size overflow")?;
                if size > max_bytes {
                    if n == 0 { return Err("checkpoint entry exceeds chunk byte bound".into()); }
                    break;
                }
                if bytes + size > max_bytes { break; }
                batch.insert(&engine.datoms, key.as_ref(), value.as_ref());
                last = Some(key.to_vec()); bytes += size; n += 1;
            }
        }
    }
    // Advance the cursor only after the whole target batch commits.
    batch.commit().map_err(|e| e.to_string())?;
    if last.is_some() { export.last = last; }
    export.entries += n; export.bytes += bytes as u64; export.exhausted = exhausted;
    Ok((exhausted, n, export.entries, bytes as u64))
}
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_checkpoint_step(artifact: ResourceArc<Artifact>, rows: usize, max_bytes: usize) -> NifResult<(bool, u64, u64, u64)> {
    if artifact.1.load(Ordering::Acquire) { return Err(err("checkpoint finalization in progress")); }
    let mut state = artifact.0.try_lock().map_err(|_| err("checkpoint operation in progress"))?;
    step(state.as_mut().ok_or_else(|| err("checkpoint aborted"))?, rows, max_bytes).map_err(err)
}

fn sync_tree(path: &Path) -> std::io::Result<()> {
    for entry in fs::read_dir(path)? {
        let entry = entry?;
        let kind = entry.file_type()?;
        if kind.is_dir() { sync_tree(&entry.path())?; }
        else if kind.is_file() { File::open(entry.path())?.sync_all()?; }
        else { return Err(std::io::Error::other("unexpected non-file in checkpoint")); }
    }
    File::open(path)?.sync_all()
}
#[cfg(target_os = "linux")]
fn publish_no_clobber(stage: &Path, destination: &Path) -> std::io::Result<()> {
    use std::os::unix::ffi::OsStrExt;
    let stage = std::ffi::CString::new(stage.as_os_str().as_bytes())?;
    let destination = std::ffi::CString::new(destination.as_os_str().as_bytes())?;
    let result = unsafe { libc::renameat2(libc::AT_FDCWD, stage.as_ptr(), libc::AT_FDCWD, destination.as_ptr(), libc::RENAME_NOREPLACE) };
    if result == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
}
#[cfg(not(target_os = "linux"))]
fn publish_no_clobber(_stage: &Path, _destination: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("atomic no-clobber directory publication unavailable"))
}
fn finish(export: &mut Export) -> Result<(), String> {
    if !export.exhausted { return Err("checkpoint scan incomplete".into()); }
    if export.stable { return Ok(()); }
    if !export.published {
        if let Some(engine) = export.engine.as_ref() {
            engine.keyspace.persist(PersistMode::SyncAll).map_err(|e| e.to_string())?;
        }
        // Close the private engine before synchronizing its full, now-stable tree.
        export.engine.take();
        let mut receipt = File::create(export.stage.join("BL_CHECKPOINT_V1")).map_err(|e| e.to_string())?;
        writeln!(receipt, "sequence={}\nentries={}\nbytes={}\nsource={}", export.sequence,
            export.entries, export.bytes, hex_path(&export.source)).map_err(|e| e.to_string())?;
        receipt.sync_all().map_err(|e| e.to_string())?;
        sync_tree(&export.stage).map_err(|e| e.to_string())?;
        export.capture.take();
        // Hold the inode flock through the atomic publication.
        publish_no_clobber(&export.stage, &export.destination).map_err(|e| e.to_string())?;
        export.published = true;
    }
    File::open(export.destination.parent().ok_or("destination parent missing")?)
        .and_then(|f| f.sync_all()).map_err(|e| e.to_string())?;
    export.stable = true;
    export.flock.take();
    Ok(())
}
fn hex_path(path: &Path) -> String {
    use std::fmt::Write;
    let mut out = String::new();
    for byte in path.to_string_lossy().as_bytes() { let _ = write!(out, "{byte:02x}"); }
    out
}
// Final sync/tree publication is deliberately NOT a DirtyIo task: a runtime
// with one dirty-I/O scheduler must still service unrelated source writes.
#[rustler::nif]
fn fjall_checkpoint_finish(artifact: ResourceArc<Artifact>, recipient: LocalPid, tag: Term) -> NifResult<Atom> {
    artifact.1.compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
        .map_err(|_| err("checkpoint finalization in progress"))?;
    let mut message_env = OwnedEnv::new();
    let saved_tag = message_env.save(tag);
    let worker_artifact = artifact.clone();
    let spawned = std::thread::Builder::new().name("datom-checkpoint-finalize".into()).spawn(move || {
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut state = worker_artifact.0.lock().map_err(|e| e.to_string())?;
            let export = state.as_mut().ok_or("checkpoint aborted")?;
            finish(export)?;
            Ok::<_, String>((export.destination.to_string_lossy().into_owned(),
                export.source.to_string_lossy().into_owned(), export.sequence, export.entries, export.bytes))
        })).unwrap_or_else(|_| Err("checkpoint finalizer panicked; inspect destination before retry".into()));
        worker_artifact.1.store(false, Ordering::Release);
        // A dead caller does not cancel an accepted publication or delete its artifact.
        let _ = message_env.send_and_clear(&recipient, |env| {
            let reply = match result { Ok(receipt) => receipt.encode(env),
                Err(reason) => (atoms::error(), reason).encode(env) };
            (saved_tag.load(env), reply).encode(env)
        });
    });
    if let Err(reason) = spawned {
        artifact.1.store(false, Ordering::Release);
        return Err(err(reason.to_string()));
    }
    Ok(atoms::accepted())
}
#[rustler::nif(schedule = "DirtyIo")]
fn fjall_checkpoint_abort(artifact: ResourceArc<Artifact>) -> NifResult<Atom> {
    if artifact.1.load(Ordering::Acquire) { return Err(err("checkpoint finalization in progress")); }
    let mut state = artifact.0.try_lock().map_err(|_| err("checkpoint operation in progress"))?;
    if state.as_ref().is_some_and(|e| e.published) { return Ok(atoms::published()); }
    state.take();
    Ok(atoms::aborted())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{claim_store, ClaimError};
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!("checkpoint-test-{}-{}", std::process::id(), NEXT_STAGE.fetch_add(1, Ordering::Relaxed)));
            fs::create_dir(&root).unwrap(); Self(root)
        }
        fn source(&self) -> (Arc<StoreClaim>, PathBuf) {
            let path = self.0.join("source");
            let claim = claim_store(&path).unwrap_or_else(|_| panic!("source open failed"));
            (claim, fs::canonicalize(path).unwrap())
        }
    }
    impl Drop for Fixture { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }
    fn drain(export: &mut Export) {
        loop { let (done, _, _, _) = step(export, 2, 4096).unwrap(); if done { break; } }
    }
    #[test]
    fn live_snapshot_is_exact_and_capture_has_no_destination_io() {
        let fixture = Fixture::new(); let (source, path) = fixture.source();
        source.engine.datoms.insert(b"a", b"old").unwrap();
        source.engine.datoms.insert(b"b", b"keep").unwrap();
        let before = fs::read_dir(&fixture.0).unwrap().count();
        let cursor = capture(source.clone(), path).unwrap();
        assert_eq!(before, fs::read_dir(&fixture.0).unwrap().count());
        source.engine.datoms.insert(b"a", b"new").unwrap();
        source.engine.datoms.remove(b"b").unwrap();
        source.engine.datoms.insert(b"c", b"later").unwrap();
        let destination = fixture.0.join("export");
        let mut export = begin(cursor, &destination).unwrap();
        assert!(matches!(claim_store(&export.stage), Err(ClaimError::Held(_))), "private export engine must refuse a second writer");
        drain(&mut export); finish(&mut export).unwrap(); finish(&mut export).unwrap();
        assert_eq!(export.entries, 2); assert!(export.stable); assert!(export.capture.is_none());
        let restored = claim_store(&destination).unwrap_or_else(|_| panic!("checkpoint open failed"));
        assert_eq!(restored.engine.datoms.get(b"a").unwrap().unwrap().as_ref(), b"old");
        assert_eq!(restored.engine.datoms.get(b"b").unwrap().unwrap().as_ref(), b"keep");
        assert!(restored.engine.datoms.get(b"c").unwrap().is_none());
        assert!(destination.join("BL_CHECKPOINT_V1").is_file());
    }
    #[test]
    fn incomplete_and_oversize_exports_never_publish_or_advance() {
        let fixture = Fixture::new(); let (source, path) = fixture.source();
        source.engine.datoms.insert(b"a", b"long-value").unwrap();
        let destination = fixture.0.join("export");
        let mut export = begin(capture(source, path).unwrap(), &destination).unwrap();
        assert!(finish(&mut export).is_err()); assert!(!destination.exists());
        assert!(step(&mut export, 1, 2).is_err());
        assert!(export.last.is_none()); assert_eq!(export.entries, 0);
        drain(&mut export); finish(&mut export).unwrap(); assert_eq!(export.entries, 1);
    }
    #[test]
    fn publication_race_never_clobbers_and_abort_removes_only_own_stage() {
        let fixture = Fixture::new(); let (source, path) = fixture.source();
        let destination = fixture.0.join("export");
        let mut export = begin(capture(source, path).unwrap(), &destination).unwrap();
        let stage = export.stage.clone(); drain(&mut export);
        fs::create_dir(&destination).unwrap(); fs::write(destination.join("sentinel"), b"existing").unwrap();
        assert!(finish(&mut export).is_err()); assert!(!export.published);
        drop(export); assert!(!stage.exists());
        assert_eq!(fs::read(destination.join("sentinel")).unwrap(), b"existing");
    }
    #[test]
    fn exact_snapshot_pins_source_claim_until_released() {
        let fixture = Fixture::new(); let (source, path) = fixture.source();
        let weak = Arc::downgrade(&source);
        let cursor = capture(source.clone(), path.clone()).unwrap(); drop(source);
        assert!(weak.upgrade().is_some());
        let joined = claim_store(&path).unwrap_or_else(|_| panic!("shared source join failed"));
        assert!(Arc::ptr_eq(&joined, &weak.upgrade().unwrap())); drop(joined);
        let mut export = begin(cursor.clone(), &fixture.0.join("export")).unwrap(); drop(cursor);
        assert!(weak.upgrade().is_some()); drain(&mut export); finish(&mut export).unwrap();
        assert!(weak.upgrade().is_none(), "completed export must release the exact source lifetime");
        let replacement = claim_store(&path).unwrap_or_else(|_| panic!("source handover failed"));
        assert_eq!(replacement.engine.datoms.len().unwrap(), 0);
    }
    #[test]
    fn overlap_and_preexisting_destination_refuse_before_staging() {
        let fixture = Fixture::new(); let (source, path) = fixture.source();
        let cursor = capture(source, path.clone()).unwrap();
        assert!(begin(cursor.clone(), &path.join("nested")).is_err());
        assert!(begin(cursor.clone(), &fixture.0).is_err());
        let existing = fixture.0.join("existing"); fs::create_dir(&existing).unwrap();
        assert!(begin(cursor, &existing).is_err());
        assert_eq!(fs::read_dir(&fixture.0).unwrap().count(), 2);
    }
}
