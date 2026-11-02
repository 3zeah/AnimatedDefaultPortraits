//! idiomatic Rust wrapper around [CascLib](https://github.com/ladislav-zezula/CascLib)

mod casc_lib;
mod error;
mod file;
mod find;
mod storage;

pub use error::{CascLibError, CascLibErrorKind};
pub use file::CascFile;
pub use find::CascSearchArgs;
pub use storage::{CascLibOrInvalidPathError, CascStorage};

/// CASC uses md5 digests both for e keys and c keys
#[repr(transparent)]
pub struct Md5Hash(pub [u8; 16]);

/// `CascOpenStorage`
///
/// entry point for local CASC storage: opens a [CascStorage] (same as ([CascStorage::open_local])
pub fn open_local_storage<P: AsRef<std::path::Path>>(
    path: P,
    product: Option<&str>,
) -> Result<CascStorage, CascLibOrInvalidPathError> {
    CascStorage::open_local(path, product)
}
