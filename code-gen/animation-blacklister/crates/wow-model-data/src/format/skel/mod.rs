mod skb1;
mod skl1;
mod skpd;
mod sks1;
mod validate;

use std::collections::HashMap;

use log::{error, trace};
use wow_parse::*;

use super::{afid, bfid};
use crate::{ArrayMap, BoneAnimations, Bones, Flags, Sequence};

#[derive(Debug)]
pub struct Skeleton {
    pub name: Option<String>,
    pub flags: Flags,
    pub skpd: Option<skpd::Chunk>,
    pub sequences: Box<[Sequence]>,
    pub animation_id_map: ArrayMap<i16>,
    pub bones: Bones,
    /// animation variation to pair of sequence index and bone animations
    pub loaded_animations: Option<HashMap<u16, (u16, BoneAnimations)>>,
    pub afid: Box<[afid::AnimationFile]>,
    pub bfid: Box<[u32]>,
}

impl Skeleton {
    pub fn parse<R: Parse>(r: &mut R, animation_to_load: u16) -> ParseResult<Self> {
        let mut skl1: Option<skl1::Chunk> = None;
        let mut skb1: Option<skb1::Chunk> = None;
        let mut sks1: Option<sks1::Chunk> = None;
        let mut skpd: Option<skpd::Chunk> = None;
        let mut afid: Vec<afid::AnimationFile> = Vec::new();
        let mut bfid: Vec<u32> = Vec::new();
        // for each chunk
        loop {
            trace!("trying to read new chunk header at {}", r.offset_in_chunk());
            const MAGIC_BYTES_LENGTH: usize = 4;
            let chunk_signature: [u8; MAGIC_BYTES_LENGTH] = match r.read_bytes_or_eof() {
                Some(some) => match some {
                    Ok(ok) => ok,
                    Err(err) => return Err(err),
                },
                None => {
                    trace!(
                        "done parsing skeleton: end of file at {}",
                        r.offset_in_chunk()
                    );
                    break;
                }
            };

            let chunk_size: u32 = r.parse_u32()?;
            trace!(
                r#"found new chunk "{}" at {}, with size {}"#,
                file_signature_lossy(&chunk_signature),
                r.offset_in_chunk(),
                chunk_size,
            );
            match &chunk_signature {
                b"SKL1" => {
                    if skl1.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    skl1 = Some(
                        r.parse_chunk(chunk_size, skl1::Chunk::parse)
                            .map_err(map_chunk_parse_error)?,
                    );
                }
                b"SKB1" => {
                    if skb1.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    let sequences = &sks1
                        .as_ref()
                        .ok_or_else(|| {
                            parse_error!("unsupported: skb1 was before sks1 in skeleton file")
                        })?
                        .sequences;
                    skb1 = Some(
                        r.parse_chunk(chunk_size, Self::skb1_parser(sequences, animation_to_load))
                            .map_err(map_chunk_parse_error)?,
                    );
                }
                b"SKS1" => {
                    if sks1.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    sks1 = Some(
                        r.parse_chunk(chunk_size, sks1::Chunk::parse)
                            .map_err(map_chunk_parse_error)?,
                    );
                }
                b"SKPD" => {
                    if skpd.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    skpd = Some(
                        r.parse_chunk(chunk_size, skpd::Chunk::parse)
                            .map_err(map_chunk_parse_error)?,
                    );
                }
                b"AFID" => {
                    let afid::Chunk { animation_files } = r
                        .parse_chunk(chunk_size, afid::Chunk::parse)
                        .map_err(map_chunk_parse_error)?;
                    afid.extend(animation_files.into_iter());
                }
                b"BFID" => {
                    let bfid::Chunk { fdids } = r
                        .parse_chunk(chunk_size, bfid::Chunk::parse)
                        .map_err(map_chunk_parse_error)?;
                    bfid.extend(fdids.into_iter());
                }
                _ => {
                    let chunk_name = file_signature(&chunk_signature)?;
                    trace!(r#"skipping irrelevant chunk "{}""#, chunk_name);
                    r.skip(chunk_size)?;
                }
            }
        }

        let skl1 = skl1.ok_or_else(|| parse_error!("no skl1 chunk"))?;

        let name = skl1.name;
        let flags = skl1.flags;
        let sks1::Chunk {
            sequences,
            animation_id_map,
        } = sks1.unwrap_or_default();
        let skb1::Chunk {
            bones,
            loaded_animations,
        } = skb1.unwrap_or_default();

        let skeleton = Skeleton {
            name,
            flags,
            skpd,
            sequences,
            animation_id_map,
            bones,
            loaded_animations,
            afid: afid.into(),
            bfid: bfid.into(),
        };

        if let Err(e) = validate::validate(&skeleton, animation_to_load) {
            trace!("validation error for skeleton: {:#?}", skeleton);
            error!("{e}");
            return Err(e);
        }

        Ok(skeleton)
    }

    fn skb1_parser<R: Parse>(
        sequences: &[Sequence],
        animation_to_load: u16,
    ) -> impl Fn(&mut R) -> ParseResult<skb1::Chunk> {
        move |r| skb1::Chunk::parse(r, sequences, animation_to_load)
    }
}

fn file_signature(magic_bytes: &[u8]) -> ParseResult<&str> {
    str::from_utf8(magic_bytes).map_err(|_| {
        parse_error!(
            r#"invalid chunk signature: expected byte string but was "{}" ({:?})"#,
            file_signature_lossy(magic_bytes),
            magic_bytes,
        )
    })
}

fn file_signature_lossy(magic_bytes: &[u8]) -> String {
    String::from_utf8_lossy(magic_bytes).to_string()
}

fn map_chunk_parse_error(err: ChunkParseError) -> ParseError {
    match err {
        e @ ChunkParseError::EnterChunkError(_) => panic!("{e}"),
        ChunkParseError::ParseError(inner) => inner,
        e @ ChunkParseError::PositionOverflow(_) => parse_error(e),
    }
}
