//! skeleton file chunk: "SKeleton Bones v1"

use std::collections::HashMap;

use log::trace;
use wow_parse::*;

use crate::format::bone::parse_bone_data;
use crate::{BoneAnimations, Bones, Sequence};

#[derive(Default, Debug)]
pub struct Chunk {
    pub bones: Bones,
    /// animation variation to pair of sequence index and bone animations
    pub loaded_animations: Option<HashMap<u16, (u16, BoneAnimations)>>,
}

#[derive(Debug)]
struct Header {
    pub bones: ArrayHeader,
}

impl Chunk {
    pub fn parse(
        r: &mut impl Parse,
        sequences: &[Sequence],
        animation_to_load: u16,
    ) -> ParseResult<Self> {
        trace!("parsing skb1 chunk");
        let header = Header::parse(r)?;
        trace!(r"skb1 header: {header:?}");
        let (bones, loaded_animations) =
            parse_bone_data(r, animation_to_load, sequences, header.bones)?;
        Ok(Self {
            bones,
            loaded_animations,
        })
    }
}

impl Header {
    pub fn parse(r: &mut impl Parse) -> ParseResult<Self> {
        let bones = r.parse_array_header()?;
        let _key_bone_id_map = r.parse_array_header()?;
        Ok(Self { bones })
    }
}
