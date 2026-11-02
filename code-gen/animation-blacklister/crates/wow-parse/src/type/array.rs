use std::fmt;

use crate::*;

#[derive(Clone, Copy)]
pub struct ArrayHeader {
    len: u32,
    offset: u32,
}

impl ArrayHeader {
    /// size in bytes of an [ArrayHeader] in a file
    const BYTES: usize = 8;

    pub fn len(&self) -> u32 {
        self.len
    }

    pub fn offset(&self) -> u32 {
        self.offset
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    pub fn validate_all_data_is_ahead<R: Parse>(&self, r: &mut R) -> ParseResult<()> {
        if self.is_empty() {
            return Ok(());
        }
        let array_header_end = r.offset_in_chunk();
        if self.offset < array_header_end {
            parse_bail!(
                "array header lists offset before header: {} < {}",
                self.offset,
                array_header_end,
            );
        };
        Ok(())
    }

    pub fn parse<R: Parse + ?Sized>(r: &mut R) -> ParseResult<ArrayHeader> {
        let len = r.parse_u32()?;
        let offset = r.parse_u32()?;
        Ok(ArrayHeader { len, offset })
    }

    pub fn from_bytes(bytes: [u8; Self::BYTES]) -> Self {
        const PART_BYTES: usize = 4;
        const { assert!(PART_BYTES * 2 == Self::BYTES) };
        let parts: &[[u8; PART_BYTES]] = unsafe { bytes.as_chunks_unchecked::<PART_BYTES>() };
        Self {
            len: u32::from_le_bytes(unsafe { *parts.get_unchecked(0) }),
            offset: u32::from_le_bytes(unsafe { *parts.get_unchecked(1) }),
        }
    }
}

impl fmt::Debug for ArrayHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_empty() {
            return write!(f, "(Array@null)");
        }
        write!(f, "(Array[{}] @ {})", self.len, self.offset)
    }
}
