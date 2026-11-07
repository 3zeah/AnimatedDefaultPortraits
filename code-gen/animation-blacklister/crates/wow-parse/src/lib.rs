mod constrained_reader;
mod parser;
mod r#type;

use std::ffi::CStr;

pub use parser::{InitParserError, Parser};
use thiserror::Error;
pub use r#type::*;

pub type ParseResult<T> = Result<T, ParseError>;

#[derive(Error, Debug)]
#[error("invalid data during parse: {0}")]
pub struct ParseError(#[from] std::io::Error);

pub fn parse_error<E>(e: E) -> ParseError
where
    E: Into<Box<dyn std::error::Error + Send + Sync>>,
{
    std::io::Error::new(std::io::ErrorKind::InvalidData, e).into()
}

#[macro_export]
macro_rules! parse_error {
    ($($arg:tt)*) => {
        parse_error(format!($($arg)*))
    };
}

#[macro_export]
macro_rules! parse_bail {
    ($($arg:tt)*) => {
        return Err(parse_error(format!($($arg)*)))
    };
}

pub trait Parse {
    fn offset_in_chunk(&self) -> u32;

    fn chunk(&self) -> Option<Chunk>;

    fn seek_in_chunk(&mut self, offset: u32) -> ParseResult<()>;

    fn skip(&mut self, len: u32) -> ParseResult<()>;

    fn read_bytes<const N: usize>(&mut self) -> ParseResult<[u8; N]>;

    fn read_bytes_or_eof<const N: usize>(&mut self) -> Option<ParseResult<[u8; N]>>;

    fn read_byte_slice(&mut self, len: u32) -> ParseResult<Box<[u8]>>;

    fn parse_chunk<Output, Format>(
        &mut self,
        size: u32,
        format: Format,
    ) -> Result<Output, ChunkParseError>
    where
        Format: Fn(&mut Self) -> ParseResult<Output>;

    fn chunk_remaining(&self) -> ParseResult<u32> {
        if let Some(chunk) = self.chunk() {
            // offset must be within chunk size, per the inner bounded reader
            Ok(chunk.size - self.offset_in_chunk())
        } else {
            Err(parse_error(
                "queried the remaining chunk size, but was not in a chunk",
            ))
        }
    }

    fn chunk_end(&self) -> ParseResult<u32> {
        Ok(self.offset_in_chunk() + self.chunk_remaining()?)
    }

    fn expect_byte_array<const N: usize>(&mut self, expected: &[u8; N]) -> ParseResult<()> {
        let actual: [u8; N] = self.read_bytes()?;
        if &actual != expected {
            Err(parse_error!(
                "read bytes did not match expectation: expected {expected:?}, but was {actual:?}",
            ))
        } else {
            Ok(())
        }
    }

    fn expect_padding(&mut self, len: u32) -> ParseResult<()> {
        let slice = self.read_byte_slice(len)?;
        if slice.into_iter().any(|b| b != 0) {
            parse_bail!("expected to read padding, but content was not empty");
        }
        Ok(())
    }

    fn expect_padding_until(&mut self, offset_in_chunk: u32) -> ParseResult<()> {
        if offset_in_chunk == self.offset_in_chunk() {
            Ok(())
        } else if offset_in_chunk < self.offset_in_chunk() {
            Err(parse_error!(
                "expected padding until {}, but was already at {}",
                offset_in_chunk,
                self.offset_in_chunk()
            ))
        } else {
            self.expect_padding(offset_in_chunk - self.offset_in_chunk())
        }
    }

    fn expect_padding_until_chunk_end(&mut self) -> ParseResult<()> {
        self.expect_padding(self.chunk_remaining()?)
    }

    fn parse_u8(&mut self) -> ParseResult<u8> {
        parse_from_bytes(self, u8::from_le_bytes)
    }

    fn parse_u16(&mut self) -> ParseResult<u16> {
        parse_from_bytes(self, u16::from_le_bytes)
    }

    fn parse_i16(&mut self) -> ParseResult<i16> {
        parse_from_bytes(self, i16::from_le_bytes)
    }

    fn parse_u32(&mut self) -> ParseResult<u32> {
        parse_from_bytes(self, u32::from_le_bytes)
    }

    fn parse_i32(&mut self) -> ParseResult<i32> {
        parse_from_bytes(self, i32::from_le_bytes)
    }

    fn parse_f32(&mut self) -> ParseResult<f32> {
        parse_from_bytes(self, f32::from_le_bytes)
    }

    fn parse_string(&mut self, len: u32) -> ParseResult<String> {
        let bytes = self.read_byte_slice(len)?;
        let c_str = CStr::from_bytes_with_nul(&bytes).map_err(|e| {
            parse_error!(
                "name was not a nul-terminated string: {} ({})",
                String::from_utf8_lossy(bytes.as_ref()),
                e
            )
        })?;
        let str = c_str.to_str().map_err(|e| {
            parse_error!(
                "name was utf 8: {} ({})",
                String::from_utf8_lossy(bytes.as_ref()),
                e,
            )
        })?;
        Ok(str.into())
    }

    fn parse_vector(&mut self) -> ParseResult<Vector> {
        Vector::parse(self)
    }

    fn parse_quat_packed(&mut self) -> ParseResult<QuatPacked> {
        QuatPacked::parse(self)
    }

    fn parse_array_header(&mut self) -> ParseResult<ArrayHeader> {
        ArrayHeader::parse(self)
    }

    fn parse_array<ElementType, ElementParse>(
        &mut self,
        len: u32,
        element_parser: ElementParse,
    ) -> ParseResult<Box<[ElementType]>>
    where
        ElementParse: Fn(&mut Self) -> ParseResult<ElementType>,
    {
        let len = len as usize;
        let mut slice: Box<[std::mem::MaybeUninit<ElementType>]> = Box::new_uninit_slice(len);
        for i in 0..len {
            let value = match element_parser(self) {
                Ok(ok) => ok,
                // MaybeUninit does not drop values: in the case of error, drop previous values
                Err(e) => {
                    for j in 0..i {
                        unsafe { slice[j].assume_init_drop() };
                    }
                    return Err(e);
                }
            };
            slice[i].write(value);
        }
        // safety: wrote to each index exactly once
        Ok(unsafe { slice.assume_init() })
    }

    fn parse_array_from_header<ElementType, ElementParse>(
        &mut self,
        header: ArrayHeader,
        element_parser: ElementParse,
    ) -> ParseResult<Box<[ElementType]>>
    where
        ElementParse: Fn(&mut Self) -> ParseResult<ElementType>,
    {
        if header.is_empty() {
            return Ok(Default::default());
        }
        self.seek_in_chunk(header.offset())?;
        self.parse_array(header.len(), element_parser)
    }

    fn parse_array_from_total_size<ElementType, ElementParse>(
        &mut self,
        size: u32,
        element_parser: ElementParse,
    ) -> ParseResult<Box<[ElementType]>>
    where
        ElementParse: Fn(&mut Self) -> ParseResult<ElementType>,
    {
        let element_size = size_of::<ElementType>() as u32;
        if size % element_size != 0 {
            parse_bail!(
                "tried to read array with total size {}, but size was not divisible by element \
                size, {}",
                size,
                element_size
            );
        }
        self.parse_array(size / element_size, element_parser)
    }
}

#[derive(Error, Debug)]
pub enum ChunkParseError {
    #[error("failed to enter chunk: {0}")]
    EnterChunkError(#[from] EnterChunkError),

    #[error("error while parsing chunk: {0}")]
    ParseError(#[from] ParseError),

    #[error(
        "reader position overflow after parsing chunk: position is out of u32 range: {} (u32::MAX \
        = {})",
        .0,
        u32::MAX
    )]
    PositionOverflow(u64),
}

#[derive(Error, Debug)]
pub enum EnterChunkError {
    #[error(
        "tried to enter chunk, but was already in chunk: was in {:?} -> tried to enter {:?}",
        prev,
        next
    )]
    AlreadyInChunk { prev: Chunk, next: Chunk },
}

#[derive(Clone, Copy, Debug)]
pub struct Chunk {
    pub offset: u32,
    pub size: u32,
}

fn parse_from_bytes<R, const N: usize, Output, FromBytes>(
    r: &mut R,
    from_bytes: FromBytes,
) -> ParseResult<Output>
where
    R: Parse + ?Sized,
    FromBytes: Fn([u8; N]) -> Output,
{
    let bytes = r.read_bytes()?;
    Ok(from_bytes(bytes))
}
