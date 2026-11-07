pub(crate) mod algebra;
pub mod animation_playlist;
pub mod blacklister;
mod file_signature;
pub mod log;
pub mod lua_gen;
pub mod resource;
pub mod skeleton;
pub mod timer;

use std::collections::{BTreeMap, HashMap};

pub use casc_lib;
pub use file_signature::*;
pub use glam;
use log::*;
use serde::Deserialize;
use skeleton::Vec3;
use thiserror::Error;
pub use wow_model_data::md21::Model;
pub use wow_parse;
use wow_parse::{ParseError, ParseResult, SplineKey, parse_bail, parse_error};

use crate::algebra::vector;
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
    pub portrait_camera: Option<StaticCamera>,
    pub character_info_camera: Option<StaticCamera>,
    wow_model_data: (
        Box<[wow_model_data::Sequence]>,
        HashMap<u16, (u16, wow_model_data::BoneAnimations)>,
    ),
}

#[derive(Clone, Copy, Debug)]
pub struct StaticCamera {
    pub far_clip: f32,
    pub near_clip: f32,
    pub position: Vec3,
    pub target: Vec3,
    pub roll: f32,
    pub fov_vertical: f32,
}

#[derive(Debug)]
pub struct AnimatedSkeleton {
    pub bind_pose: HashMap<u32, PosedBone>,
    pub animation: HashMap<u16, Animation>,
    pub portrait_camera: Option<StaticCamera>,
    pub character_info_camera: Option<StaticCamera>,
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
        const IDLE_ANIMATION: u16 = 0;
        Self::parse(storage, model_fdid, IDLE_ANIMATION)
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
                model.md20.portrait_camera,
                model.md20.character_info_camera,
            )
        } else {
            Self::from_model(
                model.md20.sequences,
                model.md20.bones.0,
                model.md20.loaded_animations,
                model.md20.portrait_camera,
                model.md20.character_info_camera,
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
            portrait_camera: self.portrait_camera,
            character_info_camera: self.character_info_camera,
        })
    }

    fn from_model(
        sequences: Box<[wow_model_data::Sequence]>,
        bones: impl AsRef<[wow_model_data::Bone]>,
        loaded_animations: Option<HashMap<u16, (u16, wow_model_data::BoneAnimations)>>,
        portrait_camera: Option<wow_model_data::CameraAnimation>,
        character_info_camera: Option<wow_model_data::CameraAnimation>,
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
        let portrait_camera = portrait_camera
            .map(StaticCamera::from_model_static)
            .transpose()?;
        let character_info_camera = character_info_camera
            .map(StaticCamera::from_model_first_frame)
            .transpose()?;
        Ok(Self {
            bind_pose,
            animation_definition,
            portrait_camera,
            character_info_camera,
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

impl StaticCamera {
    fn from_model_static(camera: wow_model_data::CameraAnimation) -> ParseResult<Self> {
        let far_clip = camera.header.far_clip;
        let near_clip = camera.header.near_clip;
        let position = vector(Self::extract_singleton_value(camera.position, "position")?);
        let target = vector(Self::extract_singleton_value(camera.target, "target")?);
        let roll = Self::extract_singleton_value(camera.roll, "roll")?;
        let fov_diagonal = Self::extract_singleton_value(camera.fov_diagonal, "fov")?;
        // TODO: we just assume square aspect ratio, but actually, there has to be some sort of
        // target fov set for player-model widgets, since they look invariant wrt aspect ratio
        let fov_vertical = fov_diagonal / f32::sqrt(2.0);
        Ok(Self {
            far_clip,
            near_clip,
            position: vector(camera.header.position) + position,
            target: vector(camera.header.target) + target,
            roll,
            fov_vertical,
        })
    }
    fn from_model_first_frame(camera: wow_model_data::CameraAnimation) -> ParseResult<Self> {
        let far_clip = camera.header.far_clip;
        let near_clip = camera.header.near_clip;
        let position = vector(
            camera
                .position
                .and_then(Self::first_value)
                .unwrap_or_default(),
        );
        let target = vector(
            camera
                .target
                .and_then(Self::first_value)
                .unwrap_or_default(),
        );
        let roll = camera.roll.and_then(Self::first_value).unwrap_or_default();
        let fov_diagonal = camera
            .fov_diagonal
            .and_then(Self::first_value)
            .unwrap_or_default();
        // TODO: we just assume square aspect ratio, but actually, there has to be some sort of
        // target fov set for player-model widgets, since they look invariant wrt aspect ratio
        let fov_vertical = fov_diagonal / f32::sqrt(2.0);
        Ok(Self {
            far_clip,
            near_clip,
            position: vector(camera.header.position) + position,
            target: vector(camera.header.target) + target,
            roll,
            fov_vertical,
        })
    }

    fn extract_singleton_value<T: Default + PartialEq + std::fmt::Debug>(
        camera_data: Option<BTreeMap<u32, SplineKey<T>>>,
        data_name: &str,
    ) -> ParseResult<T> {
        let spline_data: SplineKey<T> = if let Some(data) = camera_data {
            let mut values = data.into_values();
            let value = values.next();
            let value = if let Some(some) = value {
                some
            } else {
                return Ok(T::default());
            };
            for next_value in values {
                if next_value.value != value.value {
                    parse_bail!(
                        "unexpected: expected character camera to be static, had at least two \
                        different {data_name} values: {:?} and {:?}",
                        value,
                        next_value
                    )
                }
            }
            value
        } else {
            return Ok(T::default());
        };
        // if spline_data.tan_in != T::default() || spline_data.tan_out != T::default() {
        //     parse_bail!(
        //         "unexpected: expected character camera to be static, but had spline control \
        //         points for {data_name}: {spline_data:?}"
        //     )
        // }
        Ok(spline_data.value)
    }

    fn first_value<T: Default + PartialEq + std::fmt::Debug>(
        camera_data: BTreeMap<u32, SplineKey<T>>,
    ) -> Option<T> {
        match camera_data.into_values().next() {
            Some(v) => Some(v.value),
            None => None,
        }
    }
}
