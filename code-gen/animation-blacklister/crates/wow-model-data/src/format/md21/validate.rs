//! it is not actually particularly important that the data is consistent, for the sake of the
//! analysis of this crate, but that the data behaves as expected is the crucial sanity check that
//! the analysis is correct

use wow_parse::*;

use super::Model;

pub fn validate(model: &Model, animation_to_load: u16) -> ParseResult<()> {
    for sequence in &model.md20.sequences {
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

    for afid in &model.afid {
        if afid.animation_id == animation_to_load {
            parse_bail!(
                "unsupported: animation to load, {}, had an external file: {:?}",
                animation_to_load,
                afid
            );
        }
    }

    if model.skid.is_some() && (!model.md20.sequences.is_empty() || !model.md20.bones.0.is_empty())
    {
        parse_bail!(
            "unexpected: model had external skeleton, but also internal animations: {:?} vs {:#?}",
            model.skid,
            model.md20
        );
    }

    Ok(())
}
