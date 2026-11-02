// legacy m2 file format prior to md21, and also an md21 chunk

use std::collections::HashMap;

use log::trace;
use wow_parse::*;

use super::r#type::*;
use super::{BoneAnimations, Bones, Sequence};
use crate::format::bone::parse_bone_data;

#[derive(Debug)]
pub struct Chunk {
    pub name: Option<String>,
    pub flags: Flags,
    pub sequences: Box<[Sequence]>,
    pub animation_id_map: ArrayMap<i16>,
    pub bones: Bones,
    /// animation variation to pair of sequence index and bone animations
    pub loaded_animations: Option<HashMap<u16, (u16, BoneAnimations)>>,
}

#[derive(Debug)]
struct Header {
    name: ArrayHeader,
    flags: Flags,
    sequences: ArrayHeader,
    animation_id_map: ArrayHeader,
    bones: ArrayHeader,
}

impl Chunk {
    pub fn parse<R: Parse>(r: &mut R, animation_to_load: u16) -> ParseResult<Self> {
        trace!("parsing md20 chunk");
        let header = Header::parse(r)?;

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

        {
            trace!("begin: validate expectation that animation map keys into sequence list");
            let max_animations_i = animation_id_map
                .0
                .iter()
                .filter(|i| !i.is_negative())
                .copied()
                .max();
            if let Some(max_animations_i) = max_animations_i {
                // `as` safety: `max_animations_i` is non-negative, by above iteration filter
                if max_animations_i as usize >= sequences.len() {
                    parse_bail!(
                        "animation-id map had entry for {}, but sequence list only had length {}",
                        max_animations_i,
                        sequences.len()
                    );
                }
            }
            trace!("success: validate expectation that animation map keys into sequence list");
        }

        let (bones, loaded_animations) =
            parse_bone_data(r, animation_to_load, &sequences, header.bones)?;

        trace!("begin: reading name from {:?}", header.name);
        let name = if !header.name.is_empty() {
            r.seek_in_chunk(header.name.offset())?;
            let name = r.parse_string(header.name.len())?;
            trace!(
                r#"success: model name is "{name}" (ended at {})"#,
                r.offset_in_chunk()
            );
            Some(name)
        } else {
            trace!("no name to parse");
            None
        };

        Ok(Chunk {
            name,
            flags: header.flags,
            sequences,
            animation_id_map,
            bones,
            loaded_animations,
        })
    }
}

impl Header {
    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        r.expect_byte_array(b"MD20")?;
        let version_minor = r.parse_u8()?;
        let version_major = r.parse_u8()?;
        r.expect_padding(2)?;
        trace!("model format version: {}.{}", version_major, version_minor);
        let name = r.parse_array_header()?;

        let flags = Flags(r.parse_u32()?);

        // global loops/sequences/animations not relevant to character animations
        let _global_loops = r.parse_array_header()?;
        let sequences = r.parse_array_header()?;
        let animation_id_map = r.parse_array_header()?;
        let bones = r.parse_array_header()?;

        name.validate_all_data_is_ahead(r)?;
        sequences.validate_all_data_is_ahead(r)?;
        animation_id_map.validate_all_data_is_ahead(r)?;
        bones.validate_all_data_is_ahead(r)?;

        // skip rest: not relevant to animations
        trace!("finished parsing md20 header at {}", r.offset_in_chunk());

        // dump layout: md20 is miserably big: this is useful to confirm the format is correct
        {
            // push each array along with a name, to debug the layout
            let mut all_arrays: Vec<(ArrayHeader, String)> = Vec::new();
            for i in 0..2 {
                all_arrays.push((r.parse_array_header()?, format!("a{i}")));
            }
            trace!("num_skin_profiles = {}", r.parse_u32()?);
            for i in 0..11 {
                all_arrays.push((r.parse_array_header()?, format!("b{i}")));
            }
            trace!("bounding_box = {:?}", parse_aabb(r)?);
            trace!("bounding_sphere_radius = {:?}", r.parse_f32()?);
            trace!("collision_box = {:?}", parse_aabb(r)?);
            trace!("collision_sphere_radius = {:?}", r.parse_f32()?);
            for i in 0..11 {
                all_arrays.push((r.parse_array_header()?, format!("b{i}")));
            }

            all_arrays.push((name, "name".to_owned()));
            all_arrays.push((_global_loops, "global_loops".to_owned()));
            all_arrays.push((sequences, "sequences".to_owned()));
            all_arrays.push((animation_id_map, "animation_map".to_owned()));
            all_arrays.push((bones, "bones".to_owned()));

            all_arrays.sort_by_key(|a| a.0.offset());

            trace!("dumping md20 chunk layout defined by header:");
            let header_end = r.offset_in_chunk();
            trace!("  * {} <- end of header", header_end);
            let mut prev = header_end;
            let mut prev_len = 1;
            for (array, name) in all_arrays {
                if array.is_empty() {
                    continue;
                }
                let diff = array.offset() - prev;
                trace!(
                    "  * {} (len {}) <- {}\t\t(prev: size {}, max stride {:.1})",
                    array.offset(),
                    array.len(),
                    name,
                    diff,
                    (diff as f32) / (prev_len as f32),
                );
                prev = array.offset();
                prev_len = array.len();
            }
        }

        Ok(Header {
            name,
            flags,
            sequences,
            animation_id_map,
            bones,
        })
    }
}

// axis-aligned bounding box
fn parse_aabb<R: Parse>(r: &mut R) -> ParseResult<((f32, f32, f32), (f32, f32, f32))> {
    let min = (r.parse_f32()?, r.parse_f32()?, r.parse_f32()?);
    let max = (r.parse_f32()?, r.parse_f32()?, r.parse_f32()?);
    Ok((min, max))
}
