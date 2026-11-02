//! skeleton file chunk: "SkeLeton v1": base data for skeleton file
use log::trace;
use wow_parse::*;

use crate::Flags;

#[derive(Debug)]
pub struct Chunk {
    pub flags: Flags,
    pub name: Option<String>,
}

#[derive(Debug)]
struct Header {
    flags: Flags,
    name: ArrayHeader,
}

impl Chunk {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        trace!("parsing skl1 chunk");
        let header = Header::parse(r)?;
        trace!(
            r#"skl1 header: name = {:?}, flags = {:?}"#,
            header.name, header.flags
        );
        let name = if !header.name.is_empty() {
            header.name.validate_all_data_is_ahead(r)?;
            r.seek_in_chunk(header.name.offset())?;
            Some(r.parse_string(header.name.len())?)
        } else {
            None
        };
        let flags = header.flags;
        trace!(r"skl1: name = {name:?}, flags = {flags:?}");
        r.expect_padding_until_chunk_end()?;
        Ok(Self { flags, name })
    }
}

impl Header {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        let flags = Flags(r.parse_u32()?);
        let name = r.parse_array_header()?;
        Ok(Self { flags, name })
    }
}
