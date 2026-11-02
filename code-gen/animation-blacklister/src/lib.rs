pub mod animation_playlist;
pub mod blacklister;
mod file_signature;
pub mod log;
pub mod lua_gen;
pub mod resource;
pub mod skeleton;
pub mod timer;

use std::collections::HashMap;

pub use casc_lib;
pub use file_signature::*;
pub use glam;
use log::*;
use serde::Deserialize;
use thiserror::Error;
pub use wow_model_data::md21::Model;
pub use wow_parse;
use wow_parse::{ParseError, parse_error};

use crate::skeleton::{Animation, AnimationDefinition, PosedBone};

pub const MAGIC_BYTES_LENGTH: usize = 4;
pub type FileSignature = [u8; MAGIC_BYTES_LENGTH];

const CONFIG_PATH: &str = "config.ron";

#[derive(Deserialize, Debug)]
pub struct Config {
    pub resource: resource::Config,
    pub lua_gen: lua_gen::Config,
    pub blacklist: HashMap<u32, HashMap<Box<[String]>, Box<[u16]>>>,
    pub whitelist: HashMap<u32, Box<[String]>>,
}

#[derive(Error, Debug)]
pub enum ParseErrorOrBadCascFile {
    #[error("parse error: invalid data: {0}")]
    ParseError(#[from] wow_parse::ParseError),
    #[error("casc file could not be opened: {0}")]
    CascFileOpenError(#[source] casc_lib::CascLibError),
    #[error("casc file could not be read: {0}")]
    CascFileTestError(#[from] CascFileTestError),
}

#[derive(Debug)]
pub struct SkeletonDefinition {
    pub bind_pose: HashMap<u32, PosedBone>,
    pub animation_definition: HashMap<u16, AnimationDefinition>,
    wow_model_data: (
        Box<[wow_model_data::Sequence]>,
        HashMap<u16, (u16, wow_model_data::BoneAnimations)>,
    ),
}

#[derive(Debug)]
pub struct AnimatedSkeleton {
    pub bind_pose: HashMap<u32, PosedBone>,
    pub animation: HashMap<u16, Animation>,
}

impl Config {
    pub fn load() -> Self {
        let config_str = std::fs::read_to_string(CONFIG_PATH).expect("failed to read config");
        ron::from_str(&config_str).expect("failed to parse config")
    }
}

impl SkeletonDefinition {
    pub fn parse_for_idle(
        storage: &casc_lib::CascStorage,
        model_fdid: u32,
    ) -> Result<Self, ParseErrorOrBadCascFile> {
        Self::parse(storage, model_fdid, 0)
    }

    pub fn parse(
        storage: &casc_lib::CascStorage,
        model_fdid: u32,
        animation_id: u16,
    ) -> Result<Self, ParseErrorOrBadCascFile> {
        let model_file = storage
            .open_by_fdid(model_fdid)
            .map_err(|e| ParseErrorOrBadCascFile::CascFileOpenError(e))?;
        trace!("parsing model {model_fdid}");
        let model = parse_model(model_file, animation_id)?;
        if let Some(skid) = model.skid {
            trace!("model {model_fdid} had external skeleton file: parsing skeleton {skid}");
            let skeleton_file = storage.open_by_fdid(skid).map_err(|e| parse_error(e))?;
            let model_skeleton = parse_skeleton(skeleton_file, animation_id)?;
            Self::from_model(
                model_skeleton.sequences,
                model_skeleton.bones.0,
                model_skeleton.loaded_animations,
            )
        } else {
            Self::from_model(
                model.md20.sequences,
                model.md20.bones.0,
                model.md20.loaded_animations,
            )
        }
    }

    pub fn evaluate_into_animated_skeleton(self) -> anyhow::Result<AnimatedSkeleton> {
        let bind_pose = self.bind_pose;
        let (sequences, loaded_animations) = self.wow_model_data;
        let bones = Animation::from_model_data(sequences, loaded_animations)?;
        Ok(AnimatedSkeleton {
            bind_pose,
            animation: bones,
        })
    }

    fn from_model(
        sequences: Box<[wow_model_data::Sequence]>,
        bones: impl AsRef<[wow_model_data::Bone]>,
        loaded_animations: Option<HashMap<u16, (u16, wow_model_data::BoneAnimations)>>,
    ) -> Result<Self, ParseErrorOrBadCascFile> {
        let bind_pose = skeleton::bind_pose_from_model(bones.as_ref());
        let loaded_animations =
            loaded_animations.ok_or_else(|| parse_error!("animation in model was not loaded"))?;
        let animation_definition = loaded_animations
            .iter()
            .filter_map(|(&variation_id, &(sequence_index, _))| {
                let sequence = &sequences[usize::from(sequence_index)];
                let animation_definition = AnimationDefinition::from_sequence(sequence);
                match animation_definition {
                    Ok(ok) => match ok {
                        Some(def) => Some(Ok((variation_id, def))),
                        None => None,
                    },
                    Err(err) => Some(Err(err)),
                }
            })
            .collect::<Result<HashMap<u16, AnimationDefinition>, _>>()
            .map_err(|e| parse_error(e))?;
        Ok(Self {
            bind_pose,
            animation_definition,
            wow_model_data: (sequences, loaded_animations),
        })
    }
}

fn parse_model(
    mut r: impl std::io::Read + std::io::Seek,
    animation_to_load: u16,
) -> Result<wow_model_data::md21::Model, ParseErrorOrBadCascFile> {
    let file_signature = file_signature::read_file_signature(&mut r)?;
    if &file_signature != b"MD21" {
        return Err(file_signature::CascFileTestError::InvalidFileSignature {
            file_signature: file_signature_to_string(&file_signature),
        }
        .into());
    }
    let model = match wow_model_data::parse(r, &file_signature, animation_to_load)? {
        wow_model_data::Model::Md21(model) => model,
    };
    Ok(model)
}

fn parse_skeleton(
    mut r: impl std::io::Read + std::io::Seek,
    animation_to_load: u16,
) -> Result<wow_model_data::skel::Skeleton, ParseErrorOrBadCascFile> {
    let file_signature = file_signature::read_file_signature(&mut r)?;
    trace!(
        r#"skeleton file signature: "{}" ({file_signature:?})"#,
        file_signature_to_string(&file_signature)
    );
    if &file_signature != b"SKL1" {
        return Err(parse_error!(
            r#"not a skeleton file: found file signature "{}" ({:?})"#,
            file_signature_to_string(&file_signature),
            file_signature
        )
        .into());
    }
    r.rewind().map_err(ParseError::from)?;
    let mut parser = wow_parse::Parser::new(r, 0).map_err(ParseError::from)?;
    let skeleton = wow_model_data::skel::Skeleton::parse(&mut parser, animation_to_load)?;
    Ok(skeleton)
}

fn file_signature_to_string(magic_bytes: &[u8]) -> String {
    String::from_utf8_lossy(magic_bytes).to_string()
}
