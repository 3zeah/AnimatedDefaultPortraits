//! md21 chunk: TODO what does this do? (parent animation blacklist chunk)

use log::trace;
use wow_parse::*;

use super::super::r#type::ArrayMap;

#[derive(Debug)]
pub struct Chunk {
    pub values: ArrayMap<u16>,
}

impl Chunk {
    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        trace!("parsing pabc chunk");
        log::warn!("PABC ALERT WIOWIO");
        let header = r.parse_array_header()?;
        header.validate_all_data_is_ahead(r)?;
        r.expect_padding_until(header.offset())?;
        let values = r.parse_array_from_header(header, Parse::parse_u16)?.into();
        r.expect_padding_until_chunk_end()?;
        Ok(Self { values })
    }
}
