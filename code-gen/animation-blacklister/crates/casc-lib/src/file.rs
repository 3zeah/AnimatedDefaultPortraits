use std::error::{self, Error};
use std::io::{self, Read, Seek};
use std::marker::PhantomData;
use std::path::Path;
use std::{fmt, fs, mem, num, ptr};

use super::{CascLibError, CascStorage, casc_lib};

/// presently open file in CASC
///
/// access file contents via [Read] and [Seek]
#[derive(Debug)]
pub struct CascFile<'a> {
    handle: casc_lib::HANDLE,
    storage: PhantomData<&'a CascStorage>,
}

impl<'a> CascFile<'a> {
    /// `CascGetFileInfo` with `CASC_FILE_INFO_CLASS.CascFileFullInfo`
    pub fn get_full_info(&self) -> Result<casc_lib::CASC_FILE_FULL_INFO, CascLibError> {
        self.get_info(casc_lib::_CASC_FILE_INFO_CLASS_CascFileFullInfo)
    }

    /// `CascGetFileInfo` with `CASC_FILE_INFO_CLASS.CascFileSpanInfo`
    pub fn get_span_info(&self) -> Result<casc_lib::CASC_FILE_SPAN_INFO, CascLibError> {
        self.get_info(casc_lib::_CASC_FILE_INFO_CLASS_CascFileSpanInfo)
    }

    /// `CascGetFileSize64`
    pub fn get_size(&self) -> Result<u64, CascLibError> {
        let size: casc_lib::ULONGLONG = unsafe {
            let mut size: casc_lib::ULONGLONG = 0;
            let success = casc_lib::CascGetFileSize64(self.handle, &mut size);
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            size
        };
        Ok(size.into())
    }

    /// dump the entire contents of this CASC file to the given local file system path
    ///
    /// beware: after a call to this, the file reader will be rewound
    pub fn dump_file<P: AsRef<Path>>(&mut self, file_path: P) -> Result<(), io::Error> {
        self.rewind()?;
        let mut dump_file = fs::File::create(file_path.as_ref())?;
        let _ = io::copy(self, &mut dump_file)?;
        self.rewind()?;
        Ok(())
    }

    pub(super) fn new(_: &'a CascStorage, handle: casc_lib::HANDLE) -> Self {
        Self {
            storage: PhantomData,
            handle,
        }
    }

    fn get_info<T>(&self, info_class: casc_lib::CASC_FILE_INFO_CLASS) -> Result<T, CascLibError> {
        let result: T = unsafe {
            let mut info: Box<mem::MaybeUninit<T>> = Box::<T>::new_uninit();
            let success = casc_lib::CascGetFileInfo(
                self.handle,
                info_class,
                mem::transmute(info.as_mut_ptr()),
                size_of::<T>(),
                ptr::null_mut(),
            );
            if !success {
                return Err(CascLibError::last_casc_lib_error());
            }
            *info.assume_init()
        };
        Ok(result)
    }
}

impl Drop for CascFile<'_> {
    fn drop(&mut self) {
        unsafe {
            casc_lib::CascCloseFile(self.handle);
        }
    }
}

impl Read for CascFile<'_> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        if buf.is_empty() {
            return Ok(0);
        }
        let buf_capacity: casc_lib::DWORD = buf.len().try_into().unwrap_or(casc_lib::DWORD::MAX);
        let bytes_read: casc_lib::DWORD = unsafe {
            let mut bytes_read: casc_lib::DWORD = 0;
            let success = casc_lib::CascReadFile(
                self.handle,
                mem::transmute(&mut buf[0]),
                buf_capacity,
                &mut bytes_read,
            );
            if !success {
                return Err(io::Error::last_os_error());
            }
            bytes_read
        };
        // `as` safety: `buffer_size` <= `usize::MAX` because it is either the slice length or
        // `DWORD::MAX` when the slice length is greater than `DWORD::MAX`
        // ==> `bytes_read` <= `buffer_size` <= `usize::MAX`, because `buffer_size` is passed as
        // "bytes to read" to `CascReadFile`
        Ok(bytes_read as usize)
    }
}

impl Seek for CascFile<'_> {
    fn seek(&mut self, pos: io::SeekFrom) -> io::Result<u64> {
        let (move_method, offset_longlong) = match pos {
            io::SeekFrom::Start(offset) => {
                let offset_longlong: i64 = casc_lib::LONGLONG::try_from(offset)
                    .map_err(|e| CascFileSeekError::OffsetOverflow(offset, e))
                    .map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
                (casc_lib::FILE_BEGIN, offset_longlong)
            }
            io::SeekFrom::End(offset) => (casc_lib::FILE_END, offset),
            io::SeekFrom::Current(offset) => (casc_lib::FILE_CURRENT, offset),
        };
        let cursor: casc_lib::ULONGLONG = unsafe {
            let mut new_pos: casc_lib::ULONGLONG = 0;
            let success = casc_lib::CascSetFilePointer64(
                self.handle,
                offset_longlong,
                &mut new_pos,
                move_method,
            );
            if !success {
                return Err(io::Error::last_os_error());
            }
            new_pos
        };
        Ok(cursor.into())
    }
}

#[derive(Debug)]
enum CascFileSeekError {
    OffsetOverflow(u64, num::TryFromIntError),
}

impl error::Error for CascFileSeekError {
    fn source(&self) -> Option<&(dyn Error + 'static)> {
        match self {
            CascFileSeekError::OffsetOverflow(_, src) => Some(src),
        }
    }
}

impl fmt::Display for CascFileSeekError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CascFileSeekError::OffsetOverflow(offset, _) => {
                let max = casc_lib::LONGLONG::MAX;
                // `as` safety: this error only happens if cannot `LONGLONG::from(offset)`
                // ==> offset > LONGLONG::MAX = `max`
                let margin = *offset - max as u64;
                write!(
                    f,
                    "CascLib would overflow: cannot seek a CASC file more than LONGLONG::MAX ({}), \
                    but got LONGLONG::MAX + {} = {}",
                    max, margin, offset
                )?;
            }
        }
        Ok(())
    }
}
