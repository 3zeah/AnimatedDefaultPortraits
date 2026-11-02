use std::ffi::CString;
use std::{fmt, mem, ptr};

use super::{CascFile, CascLibError, CascStorage, Md5Hash, casc_lib};

/// the file data available from searching for, or iterating over, files in CASC
///
/// to access more data, or the content itself, [CascFindData::open] the referenced [CascFile]
#[derive(Debug)]
pub struct CascFindData<'a> {
    storage: &'a CascStorage,
    e_key: Md5Hash,
    fdid: u32,
}

/// the arguments required to initiate a CASC search: will instantiate [CascSearch] when
/// [IntoIterator]
#[derive(Debug)]
pub struct CascSearchArgs<'a> {
    storage: &'a CascStorage,
    mask: Option<CString>,
}

/// an iterator around a potentially ongoing CascLib search, via `CascFindFirstFile` and
/// `CascFindNextFile`
///
/// `CascFindFirstFile` is not called until the first file is requested
#[derive(Debug)]
pub struct CascSearch<'a> {
    handle: Option<casc_lib::HANDLE>,
    search: CascSearchArgs<'a>,
    data: casc_lib::CASC_FIND_DATA,
}

impl<'a> CascFindData<'a> {
    /// open the current file, its connection held by the returned [CascFile]
    ///
    /// convenience method: forwards to [CascStorage::open_by_e_key], which is the content
    /// identifier nearest the content itself
    pub fn open(&self) -> Result<CascFile<'a>, CascLibError> {
        self.storage.open_by_e_key(&self.e_key)
    }

    /// the file data id of the current file
    pub fn fdid(&self) -> u32 {
        self.fdid
    }

    fn from_data<'b>(
        storage: &'b CascStorage,
        data: &casc_lib::CASC_FIND_DATA,
    ) -> CascFindData<'b> {
        let e_key = Md5Hash(data.EKey);
        let fdid = data.dwFileDataId;
        CascFindData {
            storage,
            fdid,
            e_key,
        }
    }
}

impl<'a> CascSearchArgs<'a> {
    /// a search over file entries, iterating via `CascFindFirstFile` and `CascFindNextFile`
    pub(super) fn new(mask: Option<CString>, storage: &'a CascStorage) -> Self {
        Self { storage, mask }
    }
}

impl<'a> IntoIterator for CascSearchArgs<'a> {
    type Item = Result<CascFindData<'a>, CascLibError>;
    type IntoIter = CascSearch<'a>;

    fn into_iter(self) -> Self::IntoIter {
        CascSearch {
            search: self,
            handle: None,
            // safety: this is just a struct of plain old data that we will not deconstruct before
            // CascLib writes to it
            data: unsafe { mem::MaybeUninit::zeroed().assume_init() },
        }
    }
}

impl<'a> CascSearch<'a> {
    fn find_first(&mut self) -> Option<Result<CascFindData<'a>, CascLibError>> {
        let handle: casc_lib::HANDLE = unsafe {
            let mask: casc_lib::LPCSTR = self
                .search
                .mask
                .as_ref()
                .map(|m| m.as_ptr())
                .unwrap_or_else(|| ptr::null());
            let handle = casc_lib::CascFindFirstFile(
                self.search.storage.handle,
                mask,
                &mut self.data,
                ptr::null(),
            );
            if handle.is_null() {
                let code = casc_lib::GetCascError();
                if code == casc_lib::ERROR_NO_MORE_FILES {
                    return None;
                } else {
                    return Some(Err(CascLibError::from_casc_lib_code(code)).into());
                }
            }
            handle
        };
        self.handle = Some(handle);
        Some(Ok(CascFindData::from_data(self.search.storage, &self.data)))
    }
}

impl<'a> Iterator for CascSearch<'a> {
    type Item = Result<CascFindData<'a>, CascLibError>;

    fn next<'b>(&'b mut self) -> Option<Self::Item> {
        match self.handle {
            None => self.find_first(),
            Some(handle) => unsafe {
                let success = casc_lib::CascFindNextFile(handle, &mut self.data);
                if success {
                    Some(Ok(CascFindData::from_data(
                        &self.search.storage,
                        &self.data,
                    )))
                } else {
                    None
                }
            },
        }
    }
}

impl std::fmt::Debug for Md5Hash {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        // hex string as primary representation
        for byte in self.0 {
            write!(f, "{:0>2x}", byte)?;
        }
        // single-line byte array as secondary representation
        write!(f, " ({:?})", self.0)?;
        Ok(())
    }
}
