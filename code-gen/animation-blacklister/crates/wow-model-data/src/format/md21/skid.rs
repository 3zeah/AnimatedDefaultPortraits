//! md21 chunk: "SKeleton file IDs": links external skeleton files

use log::trace;
use wow_parse::*;

#[derive(Debug)]
pub struct Chunk {
    pub fdid: u32,
}

impl Chunk {
    pub fn fdid(&self) -> u32 {
        self.fdid
    }

    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        trace!("parsing skid chunk");
        let fdids = r.parse_array_from_total_size(r.chunk_remaining()?, Parse::parse_u32)?;
        if fdids.len() != 1 {
            parse_bail!("multiple files referenced in skid chunk: {fdids:?}");
        }
        Ok(Self { fdid: fdids[0] })
    }
}
