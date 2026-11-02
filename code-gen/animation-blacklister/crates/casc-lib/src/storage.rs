use std::path::{Path, PathBuf};
use std::{error, ffi, fmt, mem, ptr};

use casc_lib::_CASC_STORAGE_INFO_CLASS_CascStorageProduct;

use super::{CascFile, CascLibError, CascSearchArgs, Md5Hash, casc_lib};

/// presently open CASC storage
#[derive(Debug)]
pub struct CascStorage {
    pub(super) handle: casc_lib::HANDLE,
}

// https://github.com/ladislav-zezula/CascLib/issues/172#issuecomment-556076211
// (more discussion here: https://github.com/ladislav-zezula/CascLib/issues/178)
// it is not 100% clear to me that this is safe, but it does appear that it is INTENDED to be safe
unsafe impl Sync for CascStorage {}

impl CascStorage {
    /// `CascOpenStorage`
    ///
    /// entry point for local CASC storage (same as [super::open_local_storage])
    pub fn open_local<P: AsRef<Path>>(
        path: P,
        product: Option<&str>,
    ) -> Result<Self, CascLibOrInvalidPathError> {
        let arguments = {
            let path_str =
                path.as_ref()
                    .to_str()
                    .ok_or(CascLibOrInvalidPathError::PathUtf8Error(
                        path.as_ref().to_owned(),
                    ))?;
            let arguments_str = if let Some(p) = product {
                format!("{}*{}", path_str, p)
            } else {
                path_str.to_string()
            };
            ffi::CString::new(arguments_str)
                .map_err(|e| CascLibOrInvalidPathError::PathNulError(path_str.to_owned(), e))?
        };
        let handle: casc_lib::HANDLE = unsafe {
            let mut handle: casc_lib::HANDLE = ptr::null_mut();
            let success = casc_lib::CascOpenStorage(arguments.as_ptr().into(), 0, &mut handle);
            if !success {
                return Err(CascLibError::last_casc_lib_error().into());
            }
            handle
        };
        Ok(Self { handle })
    }

    pub fn get_product_info(&self) -> Result<casc_lib::CASC_STORAGE_PRODUCT, CascLibError> {
        let result: casc_lib::CASC_STORAGE_PRODUCT = unsafe {
            let mut product_info = Box::<casc_lib::CASC_STORAGE_PRODUCT>::new_uninit();
            let success = casc_lib::CascGetStorageInfo(
                self.handle,
                _CASC_STORAGE_INFO_CLASS_CascStorageProduct,
                mem::transmute(product_info.as_mut_ptr()),
                size_of::<casc_lib::CASC_STORAGE_PRODUCT>(),
                ptr::null_mut(),
            );
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            *product_info.assume_init()
        };
        Ok(result)
    }

    pub fn import_keys_from_file(
        &self,
        path: impl AsRef<Path>,
    ) -> Result<(), CascLibOrInvalidPathError> {
        let path_c_string = path_c_string(path)?;
        unsafe {
            let success = casc_lib::CascImportKeysFromFile(self.handle, path_c_string.as_ptr());
            if !success {
                return Err(CascLibError::last_casc_lib_error().into());
            }
        }
        Ok(())
    }

    /// a search over file entries, iterating via `CascFindFirstFile` and `CascFindNextFile`
    pub fn all_files<'a>(&'a self) -> CascSearchArgs<'a> {
        CascSearchArgs::new(None, self)
    }

    /// `CascOpenFile` with `CASC_OPEN_BY_FILEID`
    pub fn open_by_fdid<'a>(&'a self, fdid: u32) -> Result<CascFile<'a>, CascLibError> {
        let file_handle: casc_lib::HANDLE = unsafe {
            let mut file_handle: casc_lib::HANDLE = ptr::null_mut();
            let success = casc_lib::CascOpenFile(
                self.handle,
                mem::transmute(fdid as *const u32),
                0,
                casc_lib::CASC_OPEN_BY_FILEID,
                &mut file_handle,
            );
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            file_handle
        };
        Ok(CascFile::new(self, file_handle))
    }

    /// `CascOpenFile` with `CASC_OPEN_BY_EKEY`
    pub fn open_by_e_key<'a>(&'a self, e_key: &Md5Hash) -> Result<CascFile<'a>, CascLibError> {
        let file_handle: casc_lib::HANDLE = unsafe {
            let mut file_handle: casc_lib::HANDLE = ptr::null_mut();
            let success = casc_lib::CascOpenFile(
                self.handle,
                mem::transmute(e_key),
                0,
                casc_lib::CASC_OPEN_BY_EKEY,
                &mut file_handle,
            );
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            file_handle
        };
        Ok(CascFile::new(self, file_handle))
    }

    /// `CascGetStorageInfo` with `CASC_STORAGE_INFO_CLASS.CascStorageTotalFileCount`
    pub fn file_count(&self) -> Result<u32, CascLibError> {
        unsafe {
            let mut result: u32 = 0;
            let success = casc_lib::CascGetStorageInfo(
                self.handle,
                casc_lib::_CASC_STORAGE_INFO_CLASS_CascStorageTotalFileCount,
                mem::transmute(&mut result),
                mem::size_of::<u32>(),
                std::ptr::null_mut(),
            );
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            Ok(result)
        }
    }
}

impl Drop for CascStorage {
    fn drop(&mut self) {
        unsafe {
            casc_lib::CascCloseStorage(self.handle);
        }
    }
}

#[derive(Debug)]
pub enum CascLibOrInvalidPathError {
    /// path was not utf8
    PathUtf8Error(PathBuf),
    /// path contained nul
    PathNulError(String, ffi::NulError),
    /// CascLib error
    CascLibError(CascLibError),
}

fn path_c_string(path: impl AsRef<Path>) -> Result<ffi::CString, CascLibOrInvalidPathError> {
    let path_str = path
        .as_ref()
        .to_str()
        .ok_or(CascLibOrInvalidPathError::PathUtf8Error(
            path.as_ref().to_owned(),
        ))?;
    ffi::CString::new(path_str)
        .map_err(|e| CascLibOrInvalidPathError::PathNulError(path_str.to_owned(), e))
}

impl From<CascLibError> for CascLibOrInvalidPathError {
    fn from(value: CascLibError) -> Self {
        CascLibOrInvalidPathError::CascLibError(value)
    }
}

impl error::Error for CascLibOrInvalidPathError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            CascLibOrInvalidPathError::PathUtf8Error(_) => None,
            CascLibOrInvalidPathError::PathNulError(_, e) => Some(e),
            CascLibOrInvalidPathError::CascLibError(e) => Some(e),
        }
    }
}

impl fmt::Display for CascLibOrInvalidPathError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CascLibOrInvalidPathError::PathUtf8Error(p) => {
                write!(
                    f,
                    "given path was not utf8, maybe not even unicode: {:?}",
                    p
                )?;
            }
            CascLibOrInvalidPathError::PathNulError(path, _) => {
                write!(f, r#"given path as string contained nul byte: "{}""#, path)?
            }
            CascLibOrInvalidPathError::CascLibError(_) => {
                write!(f, "CascLib error")?;
            }
        }
        Ok(())
    }
}
