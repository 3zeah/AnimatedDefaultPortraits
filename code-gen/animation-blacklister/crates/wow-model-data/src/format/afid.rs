//! md21/skeleton file chunk: "Animation File IDs": links external animation files

use std::fmt;

use log::trace;
use wow_parse::*;

#[derive(Debug)]
pub struct Chunk {
    pub animation_files: Box<[AnimationFile]>,
}

#[derive(Clone, Copy)]
pub struct AnimationFile {
    pub animation_id: u16,
    pub variation: u16,
    pub fdid: u32,
}

impl Chunk {
    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        trace!("parsing afid chunk");
        let animation_files =
            r.parse_array_from_total_size(r.chunk_remaining()?, AnimationFile::parse)?;
        Ok(Self { animation_files })
    }
}

impl AnimationFile {
    fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        let animation_id = r.parse_u16()?;
        let variation = r.parse_u16()?;
        let fdid = r.parse_u32()?;
        Ok(Self {
            animation_id,
            variation,
            fdid,
        })
    }
}

impl fmt::Debug for AnimationFile {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "afid::Data {{ ({}, {}): {} }}",
            self.animation_id, self.variation, self.fdid
        )
    }
}
