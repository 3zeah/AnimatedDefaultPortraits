use std::io;

use casc_lib::CascLibErrorKind;
use thiserror::Error;

use crate::{FileSignature, MAGIC_BYTES_LENGTH};

#[derive(Error, Debug)]
pub enum CascFileTestError {
    #[error("file was empty")]
    EmptyFile,

    #[error("file was encrypted")]
    EncryptedFile(#[source] io::Error),

    #[error("some sort of data corruption is going on")]
    DataCorruption(#[source] io::Error),

    #[error("file was not found, likely due to corrupt indices")]
    FileNotFound(#[source] io::Error),

    #[error(
        r#"invalid file signature: read file signature "{:?}" (from 4 magic bytes)"#, 
        .file_signature
    )]
    InvalidFileSignature { file_signature: String },

    #[error("unknown io error")]
    Unknown(#[source] io::Error),
}

pub fn read_file_signature(r: &mut impl io::Read) -> Result<FileSignature, CascFileTestError> {
    let mut magic_number = [0u8; MAGIC_BYTES_LENGTH];
    let mut total_read = 0;
    while total_read < MAGIC_BYTES_LENGTH {
        let bytes_read = r
            .read(&mut magic_number[total_read..])
            .map_err(from_io_error)?;
        if bytes_read == 0 {
            break;
        }
        total_read += bytes_read;
    }
    if total_read == 0 {
        return Err(CascFileTestError::EmptyFile);
    } else if total_read != MAGIC_BYTES_LENGTH {
        let file_signature = file_signature(&magic_number[0..total_read]);
        return Err(CascFileTestError::InvalidFileSignature { file_signature });
    }
    Ok(magic_number)
}

fn file_signature(magic_bytes: &[u8]) -> String {
    String::from_utf8_lossy(magic_bytes).to_string()
}

fn from_io_error(err: io::Error) -> CascFileTestError {
    if let Some(code) = err.raw_os_error() {
        match CascLibErrorKind::from(code) {
            CascLibErrorKind::EncryptedFile => CascFileTestError::EncryptedFile(err),
            CascLibErrorKind::NotSupported => CascFileTestError::DataCorruption(err),
            CascLibErrorKind::FileNotFound => CascFileTestError::FileNotFound(err),
            CascLibErrorKind::Uncategorized => CascFileTestError::Unknown(err),
        }
    } else {
        CascFileTestError::Unknown(err)
    }
}
