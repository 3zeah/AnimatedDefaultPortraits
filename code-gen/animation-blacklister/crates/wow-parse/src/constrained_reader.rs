use std::io::{self, BufReader, Read, Seek};

use thiserror::Error;

use super::{Chunk, EnterChunkError, InitParserError};

// TODO is this completrely supplanted by std::io::Take lol
// TODO i see now that moving into eg Take and then moving OUT with into_inner is the way to handle the push/pop issue of chunks
// TODO the type system should tell us whether a reader is currently in chunk mode

/// wrapper around reader that, for the sake of sanity, errors when reading outside its pre-assigned
/// chunk
#[derive(Debug)]
pub(super) struct ChunkReader<R: Read + io::Seek + ?Sized> {
    offset_in_chunk: u32,
    chunk: Option<Chunk>,
    inner: BufReader<R>,
}

#[derive(Error, Debug)]
enum ChunkReadError {
    #[error(
        "reader out of bounds: offset in chunk was {}, but chunk range was [0, {})",
        offset_in_chunk,
        size
    )]
    OutOfBounds { offset_in_chunk: i64, size: u32 },
}

#[derive(Error, Debug)]
pub enum LeaveChunkError {
    #[error("tried to leave chunk, but was not in one")]
    NotInChunk,

    #[error(
        "reader position overflow: position is out of u32 range: {} (u32::MAX = {})",
        .0,
        u32::MAX
    )]
    PositionOverflow(u64),
}

impl<R: Read + io::Seek> ChunkReader<R> {
    pub fn offset_in_chunk(&self) -> u32 {
        self.offset_in_chunk
    }

    pub fn chunk(&self) -> Option<Chunk> {
        self.chunk
    }

    pub fn read_exact(&mut self, buf: &mut [u8]) -> io::Result<()> {
        self.inner.read_exact(buf)?;
        let new_offset_i64 =
            i64::from(self.offset_in_chunk).saturating_add(i64::try_from(buf.len()).expect("TODO"));
        let new_offset =
            u32::try_from(new_offset_i64).map_err(|_| self.out_of_bounds_error(new_offset_i64))?;
        self.offset_in_chunk = new_offset;
        self.validate_in_bounds()?;
        Ok(())
    }

    pub fn seek_in_chunk(&mut self, offset: u32) -> io::Result<()> {
        if offset == self.offset_in_chunk {
            return Ok(());
        }
        let offset_delta = i64::from(offset) - i64::from(self.offset_in_chunk);
        self.offset_in_chunk = offset;
        self.validate_in_bounds()?;
        self.inner.seek_relative(offset_delta)?;
        Ok(())
    }

    pub fn seek_relative(&mut self, offset: i64) -> io::Result<()> {
        if offset == 0 {
            return Ok(());
        }
        let new_offset_i64 = i64::from(self.offset_in_chunk).saturating_add(offset);
        let new_offset =
            u32::try_from(new_offset_i64).map_err(|_| self.out_of_bounds_error(new_offset_i64))?;
        self.offset_in_chunk = new_offset;
        self.validate_in_bounds()?;
        self.inner.seek_relative(offset)?;
        Ok(())
    }

    fn validate_in_bounds(&self) -> io::Result<()> {
        if let Some(chunk) = self.chunk
            && self.offset_in_chunk > chunk.size
        {
            return Err(self.out_of_bounds_error(self.offset_in_chunk.into()));
        }
        Ok(())
    }

    pub fn new(inner: R, stream_position: u32) -> Result<Self, InitParserError> {
        Ok(Self {
            offset_in_chunk: stream_position,
            chunk: None,
            inner: BufReader::new(inner),
        })
    }

    /// enter a chunk of the given size, potentially having already read the given number of bytes
    /// from it
    pub fn enter_chunk(&mut self, size: u32) -> Result<(), EnterChunkError> {
        let chunk = Chunk {
            offset: self.offset_in_chunk(),
            size,
        };
        // nested chunks not supported (no use case for it)
        if let Some(prev) = self.chunk {
            return Err(EnterChunkError::AlreadyInChunk { prev, next: chunk });
        }
        self.offset_in_chunk = 0;
        self.chunk = Some(chunk);
        Ok(())
    }

    pub fn leave_chunk(&mut self) -> Result<(), LeaveChunkError> {
        let Chunk { offset, .. } = match self.chunk.take() {
            Some(ok) => ok,
            None => return Err(LeaveChunkError::NotInChunk),
        };
        let new_offset = match self.offset_in_chunk.checked_add(offset) {
            Some(ok) => ok,
            None => {
                return Err(LeaveChunkError::PositionOverflow(
                    u64::from(self.offset_in_chunk).saturating_add(offset.into()),
                ));
            }
        };
        self.offset_in_chunk = new_offset;
        Ok(())
    }

    fn out_of_bounds_error_from_read<T: TryInto<i64>>(&self, read_size: T) -> io::Error {
        self.out_of_bounds_error(
            i64::from(self.offset_in_chunk) + read_size.try_into().unwrap_or(i64::MAX),
        )
    }

    fn out_of_bounds_error(&self, position: i64) -> io::Error {
        io::Error::other(ChunkReadError::OutOfBounds {
            offset_in_chunk: position,
            size: self.chunk.as_ref().map(Chunk::size).unwrap_or(u32::MAX),
        })
    }

    fn relativize_position(&self, absolute: u64) -> io::Result<u32> {
        match self.chunk {
            Some(chunk) => {
                let position_i64 = match i64::try_from(absolute) {
                    Ok(ok) => ok,
                    Err(_) => {
                        return Err(self.out_of_bounds_error(u32::MAX.into()));
                    }
                };
                let new_offset =
                    u32::try_from(position_i64.saturating_sub(i64::from(chunk.offset)))
                        .map_err(|_| self.out_of_bounds_error(position_i64))?;
                if new_offset > chunk.size {
                    return Err(self.out_of_bounds_error(new_offset.into()));
                }
                Ok(new_offset)
            }
            None => u32::try_from(absolute).map_err(|_| self.out_of_bounds_error(u32::MAX.into())),
        }
    }
}

impl Chunk {
    fn size(&self) -> u32 {
        self.size
    }
}

impl<R: Read + io::Seek> Read for ChunkReader<R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let read_size = self.inner.read(buf)?;
        let read_size_u32 = match u32::try_from(read_size) {
            Ok(ok) => ok,
            Err(_) => {
                return Err(self.out_of_bounds_error_from_read(read_size));
            }
        };
        let new_offset = self.offset_in_chunk.checked_add(read_size_u32);
        match new_offset {
            Some(new_offset) => {
                if let Some(chunk) = self.chunk
                    && new_offset > chunk.size
                {
                    return Err(self.out_of_bounds_error(new_offset.into()));
                }
                self.offset_in_chunk = new_offset;
            }
            None => {
                return Err(self.out_of_bounds_error_from_read(read_size));
            }
        }
        Ok(read_size)
    }
}

impl<R: Read + Seek> Seek for ChunkReader<R> {
    fn seek(&mut self, pos: io::SeekFrom) -> io::Result<u64> {
        let new_position = self.inner.seek(pos)?;
        self.offset_in_chunk = self.relativize_position(new_position)?;
        Ok(new_position)
    }
}
