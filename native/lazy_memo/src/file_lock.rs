//! OS custody for cache generations and build workspaces. Lock files are
//! permanent anchors outside the directory being protected: never unlink one.
use rustler::{Atom, Env, LocalPid, Monitor, NifResult, ResourceArc};
use std::fs::{File, OpenOptions, TryLockError};
use std::sync::Mutex;

rustler::atoms! { ok, busy }

pub struct FileLock(Mutex<Option<File>>);

impl FileLock {
    fn close(&self) {
        self.0.lock().unwrap_or_else(|e| e.into_inner()).take();
    }
}

#[rustler::resource_impl]
impl rustler::Resource for FileLock {
    fn down(&self, _env: Env<'_>, _pid: LocalPid, _monitor: Monitor) {
        self.close();
    }
}

#[rustler::nif(name = "nif_file_lock", schedule = "DirtyIo")]
fn acquire(env: Env<'_>, path: String, shared: bool, monitor_owner: bool)
    -> NifResult<(Atom, Option<ResourceArc<FileLock>>)>
{
    let io_error = |e: std::io::Error| rustler::Error::Term(Box::new(e.to_string()));
    if let Some(parent) = std::path::Path::new(&path).parent() {
        std::fs::create_dir_all(parent).map_err(io_error)?;
    }
    let file = OpenOptions::new().read(true).write(true).create(true)
        .truncate(false).open(path).map_err(io_error)?;
    let locked = if shared { file.try_lock_shared() } else { file.try_lock() };
    match locked {
        Ok(()) => {
            let resource = ResourceArc::new(FileLock(Mutex::new(Some(file))));
            if monitor_owner && resource.monitor(Some(env), &env.pid()).is_none() {
                resource.close();
                return Err(rustler::Error::BadArg);
            }
            Ok((ok(), Some(resource)))
        }
        Err(TryLockError::WouldBlock) => Ok((busy(), None)),
        Err(TryLockError::Error(e)) => Err(io_error(e)),
    }
}

#[rustler::nif(name = "nif_file_unlock", schedule = "DirtyIo")]
fn release(resource: ResourceArc<FileLock>) -> Atom {
    resource.close();
    ok()
}
