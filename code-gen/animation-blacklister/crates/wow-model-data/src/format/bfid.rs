//! md21/skeleton file chunk: "Bone File IDs": links external bone files, but apparently this is
//! only relevant for the 808 animation (?), and thus can be ignored, since this system only
//! analyses the idle animation

use log::trace;
use wow_parse::*;

#[derive(Debug)]
pub struct Chunk {
    pub fdids: Box<[u32]>,
}

impl Chunk {
    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        trace!("parsing bfid chunk");
        let fdids = r.parse_array_from_total_size(r.chunk_remaining()?, Parse::parse_u32)?;
        Ok(Self { fdids })
    }
}
