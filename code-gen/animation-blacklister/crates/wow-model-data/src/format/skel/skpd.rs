//! skeleton file chunk: "SKeleton Parent Data": it appears that even skeletons with parents have
//! sequence and bone data, which is all in which we are interested

use log::trace;
use wow_parse::*;

#[derive(Default, Debug)]
pub struct Chunk {
    pub parent_fdid: u32,
}

impl Chunk {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        trace!("parsing skpd chunk");
        r.expect_padding(8)?;
        let parent_fdid = r.parse_u32()?;
        trace!("skpd: parent fdid = {parent_fdid}");
        r.expect_padding_until_chunk_end()?;
        Ok(Self { parent_fdid })
    }
}
