mod format;

use std::io;

pub use format::*;
use wow_parse::*;

#[derive(Debug)]
pub enum Model {
    Md21(md21::Model),
}

pub fn parse(
    r: impl io::Read + io::Seek,
    file_signature: &[u8; 4],
    animation_to_load: u16,
) -> Result<Model, ParseError> {
    let stream_position = u32::try_from(file_signature.len()).unwrap();
    let mut parser = Parser::new(r, stream_position)?;
    match file_signature {
        // old m20 models do not appear to exist anymore
        b"MD20" => parse_bail!("unsupported: encountered legacy md20 model"),
        b"MD21" => Ok(Model::Md21(md21::Model::parse(
            &mut parser,
            animation_to_load,
        )?)),
        b"M3DT" => parse_bail!("unsupported: encountered m3 model"),
        _ => parse_bail!(
            r#"invalid signature: "{}" ({:?}) is not a model"#,
            file_signature_to_string(file_signature),
            file_signature
        ),
    }
}

fn file_signature_to_string(magic_bytes: &[u8]) -> String {
    String::from_utf8_lossy(magic_bytes).to_string()
}
