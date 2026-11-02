use wow_parse::*;

use super::Skeleton;

pub fn validate(skeleton: &Skeleton, animation_to_load: u16) -> ParseResult<()> {
    for sequence in &skeleton.sequences {
        if sequence.animation_id != animation_to_load {
            continue;
        }
        if !sequence.is_primary {
            parse_bail!(
                "unsupported: animation to load, {}, was not primary: {:?}",
                animation_to_load,
                sequence
            );
        }
    }

    for afid in &skeleton.afid {
        if afid.animation_id == animation_to_load {
            parse_bail!(
                "unsupported: animation to load, {}, had an external file: {:?}",
                animation_to_load,
                afid
            );
        }
    }

    Ok(())
}
