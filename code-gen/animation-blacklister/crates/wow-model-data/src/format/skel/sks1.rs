//! skeleton file chunk: "SKeleton Sequences v1"
use log::trace;
use wow_parse::*;

use crate::{ArrayMap, Sequence};

#[derive(Default, Debug)]
pub struct Chunk {
    pub sequences: Box<[Sequence]>,
    pub animation_id_map: ArrayMap<i16>,
}

#[derive(Debug)]
struct Header {
    sequences: ArrayHeader,
    animation_id_map: ArrayHeader,
}

impl Chunk {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        trace!("parsing sks1 chunk");
        let header = Header::parse(r)?;
        trace!(r"sks1 header: {header:?}");
        trace!("begin: reading sequences from {:?}", header.sequences);
        let sequences = r.parse_array_from_header(header.sequences, Sequence::parse)?;
        trace!(
            "success: parse sequences (ended at {})",
            r.offset_in_chunk()
        );

        trace!(
            "begin: reading animation-map entries from {:?}",
            header.animation_id_map
        );
        let animation_id_map =
            ArrayMap(r.parse_array_from_header(header.animation_id_map, Parse::parse_i16)?);
        trace!(
            "success: parse animation map (ended at {})",
            r.offset_in_chunk()
        );
        Ok(Self {
            sequences,
            animation_id_map,
        })
    }
}

impl Header {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        let _global_loops = r.parse_array_header()?;
        let sequences = r.parse_array_header()?;
        let animation_id_map = r.parse_array_header()?;
        Ok(Self {
            sequences,
            animation_id_map,
        })
    }
}
