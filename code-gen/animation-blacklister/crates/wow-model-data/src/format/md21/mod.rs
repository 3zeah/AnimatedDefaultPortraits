pub mod pabc;
pub mod skid;
mod validate;

use log::{error, trace};
use wow_parse::*;

use super::{afid, bfid, md20};

#[derive(Debug)]
pub struct Model {
    pub md20: md20::Chunk,
    pub afid: Box<[afid::AnimationFile]>,
    pub bfid: Box<[u32]>,
    pub skid: Option<u32>,
    pub pabc: Option<pabc::Chunk>,
}

impl Model {
    pub fn parse<R: Parse>(r: &mut R, animation_to_load: u16) -> ParseResult<Self> {
        // because the size of the m20 chunk is provided before the m20 chunk signature, it appears
        // safe to assume that the m20 chunk has to be first, and is not processed along with the
        // rest of the chunks
        let md20: md20::Chunk = {
            let chunk_size = r.parse_u32()?;
            trace!(
                r#"found md20 chunk at {}, with size {}"#,
                r.offset_in_chunk(),
                chunk_size,
            );
            let chunk: md20::Chunk = r
                .parse_chunk(chunk_size, Self::md20_parser(animation_to_load))
                .map_err(map_chunk_parse_error)?;
            chunk
        };
        let mut afid: Vec<afid::AnimationFile> = Vec::new();
        let mut bfid: Vec<u32> = Vec::new();
        let mut skid: Option<skid::Chunk> = None;
        let mut pabc: Option<pabc::Chunk> = None;
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
                    trace!("done parsing model: end of file at {}", r.offset_in_chunk());
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
                b"MD20" => {
                    parse_bail!(
                        r#"encountered multiple "{0}" chunks"#,
                        // unwrap will not fail: `chunk_signature` was matched as byte string
                        file_signature(&chunk_signature).unwrap()
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
                b"SKID" => {
                    if skid.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    skid = Some(
                        r.parse_chunk(chunk_size, skid::Chunk::parse)
                            .map_err(map_chunk_parse_error)?,
                    );
                }
                b"PABC" => {
                    if pabc.is_some() {
                        parse_bail!(
                            r#"encountered multiple "{0}" chunks"#,
                            // unwrap will not fail: `chunk_signature` was matched as byte string
                            file_signature(&chunk_signature).unwrap()
                        );
                    };
                    pabc = Some(
                        r.parse_chunk(chunk_size, pabc::Chunk::parse)
                            .map_err(map_chunk_parse_error)?,
                    )
                }
                _ => {
                    let chunk_name = file_signature(&chunk_signature)?;
                    trace!(r#"skipping irrelevant chunk "{}""#, chunk_name);
                    r.skip(chunk_size)?;
                }
            }
        }

        let model = Model {
            md20,
            afid: afid.into(),
            bfid: bfid.into(),
            skid: skid.as_ref().map(skid::Chunk::fdid),
            pabc,
        };

        if let Err(e) = validate::validate(&model, animation_to_load) {
            trace!("validation error for model: {:#?}", model);
            error!("{e}");
            return Err(e);
        }

        Ok(model)
    }

    fn md20_parser<R: Parse>(
        animation_to_load: u16,
    ) -> impl Fn(&mut R) -> ParseResult<md20::Chunk> {
        move |r| md20::Chunk::parse(r, animation_to_load)
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
