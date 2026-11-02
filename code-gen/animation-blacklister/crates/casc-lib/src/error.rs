use std::{error, fmt, io};

use super::casc_lib;

/// error forwarded from CascLib
#[derive(Debug)]
pub struct CascLibError {
    code: casc_lib::DWORD,
    message: String,
}

/// some potentially interesting types of [CascLibError] codes, constructed [From] such codes, or
/// OS error codes, which are equivalent
#[derive(Debug)]
pub enum CascLibErrorKind {
    EncryptedFile,
    NotSupported,
    FileNotFound,
    Uncategorized,
}

impl CascLibError {
    pub fn kind(&self) -> CascLibErrorKind {
        self.code.into()
    }

    pub(super) fn last_casc_lib_error() -> Self {
        let code: casc_lib::DWORD = unsafe { casc_lib::GetCascError() };
        Self::from_casc_lib_code(code)
    }

    pub(super) fn from_casc_lib_code(code: casc_lib::DWORD) -> Self {
        let message = Self::get_casc_lib_error_message(code);
        if code == 0 {
            Self::new(
                code,
                format!("but CascLib did not report an error ({})", message),
            )
        } else {
            Self::new(code, message)
        }
    }

    fn new(code: casc_lib::DWORD, message: String) -> Self {
        Self { code, message }
    }

    fn get_casc_lib_error_message(code: casc_lib::DWORD) -> String {
        // `as` safety: if we have an error code, it came from the platform, and thus we can trust
        // rust that it fits here (technically, once stable, we should use `as io::RawOsError`:
        // https://github.com/rust-lang/rust/issues/107792)
        let io_error = io::Error::from_raw_os_error(code as i32);
        // gotta take the long way around here, since `std::sys` is not public: what we really want
        // is simply `sys::io::error_string(code)`
        io_error.to_string()
    }
}

impl error::Error for CascLibError {}

impl fmt::Display for CascLibError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "CascLib error {}: {}", self.code, self.message)
    }
}

impl From<i32> for CascLibErrorKind {
    fn from(value: i32) -> Self {
        // `as` safety: technically, once stable, this should be `From<io::RawOsError`
        // (https://github.com/rust-lang/rust/issues/107792), but presently, rust guarantees that
        // the error code of any normal platform will fit `i32`: "raw os" io errors use `i32`
        (value as casc_lib::DWORD).into()
    }
}

impl From<casc_lib::DWORD> for CascLibErrorKind {
    fn from(value: casc_lib::DWORD) -> Self {
        match value {
            casc_lib::ERROR_FILE_ENCRYPTED => CascLibErrorKind::EncryptedFile,
            casc_lib::ERROR_NOT_SUPPORTED => CascLibErrorKind::NotSupported,
            casc_lib::ERROR_FILE_NOT_FOUND => CascLibErrorKind::FileNotFound,
            _ => CascLibErrorKind::Uncategorized,
        }
    }
}

impl TryFrom<io::Error> for CascLibErrorKind {
    type Error = ();

    fn try_from(value: io::Error) -> Result<Self, Self::Error> {
        if let Some(code) = value.raw_os_error() {
            Ok(code.into())
        } else {
            Err(())
        }
    }
}
