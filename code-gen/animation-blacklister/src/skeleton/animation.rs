use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt::Debug;
use std::mem::MaybeUninit;

use anyhow::{Result, anyhow, bail};
use glam::Affine3;

use super::algebra::*;
use super::similarity::mean_skeleton_error;
use super::{Vec3, lerp};
use crate::Model;

pub type Frame = u16;

#[derive(Debug)]
pub struct Animation {
    pub duration: Frame,
    pub frequency: f32,
    pub replay_range: Option<(u32, u32)>,
    pub skeleton: HashMap<u32, AnimatedBone>,
}

#[derive(Debug)]
pub struct AnimationDefinition {
    pub duration: Frame,
    pub frequency: f32,
    pub replay_range: Option<(u32, u32)>,
}

pub struct AnimatedBone {
    pub parent_id: Option<u32>,
    pub positions: Box<[Vec3]>,
}

#[derive(Debug)]
struct Bone {
    name_crc: u32,
    key_bone_id: Option<u32>,
    parent_index: Option<usize>,
    bind_position: glam::Vec3,
    transforms: Box<[glam::Affine3]>,
    debug_bind_position: glam::Vec3,
}

struct ValueOverTime<T: Default> {
    should_interpolate: bool,
    changes: BTreeMap<u32, T>,
}

impl Animation {
    pub const FPS: Frame = 30;

    pub fn duration_sec(&self) -> f32 {
        f32::from(self.duration) / f32::from(Self::FPS)
    }

    pub fn mean_error(a: &Self, b: &Self) -> f32 {
        if a.duration != b.duration {
            return f32::MAX;
        }
        mean_skeleton_error(&a.skeleton, &b.skeleton, |a_skeleton, b_skeleton| {
            let errors = a_skeleton
                .positions
                .iter()
                .zip(b_skeleton.positions.iter())
                .map(|(&a, &b)| glam::Vec3::distance_squared(a, b))
                .collect::<Vec<_>>();
            let errors_len = errors.len() as f32;
            errors.into_iter().sum::<f32>() / errors_len
        })
    }

    pub fn from_model_data(
        sequences: impl AsRef<[wow_model_data::Sequence]>,
        loaded_animations: HashMap<u16, (u16, wow_model_data::BoneAnimations)>,
    ) -> Result<HashMap<u16, Self>> {
        loaded_animations
            .into_iter()
            .map(Self::from_model_animation_entry_fn(sequences.as_ref()))
            .filter_map(transpose_map_entry)
            .collect()
    }

    pub fn from_loaded_animation(model: Model) -> Result<HashMap<u16, Self>> {
        let sequences = model.md20.sequences;
        let loaded_animations = model.md20.loaded_animations.ok_or_else(|| {
            anyhow!("model had no loaded animation: the animation must be missing")
        })?;
        Self::from_model_data(sequences, loaded_animations)
    }

    // TODO bunch of annoying overloads here that can we can probably bin after both mains go via
    // the new animation-def api, and maybe this api should be integrated into this mod
    pub fn from_loaded_animation_skeleton(
        skeleton: wow_model_data::skel::Skeleton,
    ) -> Result<HashMap<u16, Self>> {
        let sequences = skeleton.sequences;
        let loaded_animations = skeleton.loaded_animations.ok_or_else(|| {
            anyhow!("skeleton had no loaded animation: the animation must be missing")
        })?;
        Self::from_model_data(sequences, loaded_animations)
    }

    // closure glue to process map of tuples
    fn from_model_animation_entry_fn(
        sequences: impl AsRef<[wow_model_data::Sequence]>,
    ) -> impl FnMut((u16, (u16, wow_model_data::BoneAnimations))) -> Result<(u16, Option<Self>)>
    {
        move |(k, (sequence_index, bones))| {
            let sequence = sequences
                .as_ref()
                .get(usize::from(sequence_index))
                .ok_or_else(|| {
                    anyhow!(
                        "sequence {} did not exist (sequences: {:?})",
                        sequence_index,
                        sequences.as_ref()
                    )
                })?;
            let bone = Self::from_model_bones(sequence, bones)?;
            Ok((k, bone))
        }
    }

    fn from_model_bones(
        sequence: &wow_model_data::Sequence,
        bones: wow_model_data::BoneAnimations,
    ) -> Result<Option<Self>> {
        let AnimationDefinition {
            duration,
            frequency,
            replay_range,
        } = if let Some(some) = AnimationDefinition::from_sequence(sequence)? {
            some
        } else {
            return Ok(None);
        };

        let bones = Bone::from_model_bones(duration, Self::FPS, bones.0);
        let mut is_in_key_bone_skeleton: HashSet<usize> = HashSet::new();
        let mut skeleton: HashMap<u32, AnimatedBone> = HashMap::new();
        // bones are stored in parent-first order: by iterating from the back, and marking parents
        // of key bones, the result will contain all bones that are in key-bone hierarchies
        for (i, bone) in bones.iter().enumerate().rev() {
            let bone_id_to_add = if let Some(key_bone_id) = bone.key_bone_id {
                Some(key_bone_id)
            } else if is_in_key_bone_skeleton.contains(&i) {
                Some(bone.name_crc)
            } else {
                None
            };
            // let bone_id_to_add = Some(bone.bone_id()); // TODO sometiems this might be betteR?
            // ^if this is changed, also change `super::bind`
            if let Some(bone_id) = bone_id_to_add {
                let parent_id = if let Some(parent_index) = bone.parent_index {
                    assert!(parent_index < i, "bones were not stored with parents first");
                    is_in_key_bone_skeleton.insert(parent_index.into());
                    Some(bones[usize::from(parent_index)].bone_id())
                } else {
                    None
                };
                let positions = bone
                    .transforms
                    .iter()
                    .map(|t| t.transform_point3(glam::Vec3::ZERO))
                    .collect();
                let animated_bone = AnimatedBone {
                    parent_id,
                    positions,
                };
                skeleton.insert(bone_id, animated_bone);
            }
        }
        Ok(Some(Self {
            duration,
            frequency,
            replay_range,
            skeleton,
        }))
    }
}

impl AnimationDefinition {
    pub fn from_sequence(sequence: &wow_model_data::Sequence) -> Result<Option<Self>> {
        let duration = frames_from_duration(sequence.duration, Animation::FPS)?;
        // not a real animation
        if duration == 0 {
            return Ok(None);
        }
        if sequence.frequency < 0 {
            bail!(
                "frequency was negative: {} (in sequence {:?})",
                sequence.frequency,
                sequence
            );
        }
        let frequency = f32::from(sequence.frequency) / f32::from(i16::MAX);
        {
            // TODO confirm that (0, 0) = (1, 1)
            let (min, max) = sequence.replay_range;
            if max == 1 && min == 0 {
                bail!("found a [0, 1] range");
            }
        }
        if frequency == 0.0 {
            return Ok(None);
        }
        let replay_range = Some(sequence.replay_range).filter(|&(_, max)| max > 1);
        if let Some((min, max)) = replay_range {
            if min > max {
                bail!(
                    "min > max in replay range: ({}, {}) (in sequence {:?})",
                    min,
                    max,
                    sequence
                );
            }
        }
        Ok(Some(Self {
            duration,
            frequency,
            replay_range,
        }))
    }
}

impl Bone {
    fn bone_id(&self) -> u32 {
        self.key_bone_id.unwrap_or(self.name_crc)
    }

    fn from_model_bones(
        duration: u16,
        fps: Frame,
        bones: Box<[wow_model_data::BoneAnimation]>,
    ) -> Box<[Bone]> {
        let bind_positions: Box<[glam::Vec3]> = bones.iter().map(Self::bind_position).collect();
        let bone_count = bones.len();
        let mut local_bones_build = Box::new_uninit_slice(bone_count);
        for (i, model_bone) in bones.into_iter().enumerate() {
            let parent_bind_position = model_bone
                .parent()
                .map(|parent| bind_positions[usize::from(parent)])
                .unwrap_or(glam::Vec3::ZERO);
            let local_bind_position = vector(model_bone.pivot) - parent_bind_position;
            let debug_bind_position = vector(model_bone.pivot); // TODO debug
            let bone = Bone::from_model_bone(
                duration,
                fps,
                model_bone,
                local_bind_position,
                debug_bind_position,
            );
            local_bones_build[i].write(bone);
        }
        let local_bones = unsafe { local_bones_build.assume_init() };
        Self::propagate_parent_transforms(duration, local_bones)
    }

    fn propagate_parent_transforms(duration: u16, local_bones: Box<[Self]>) -> Box<[Self]> {
        let mut result: Box<[MaybeUninit<Self>]> = Box::new_uninit_slice(local_bones.len());
        for (i, local_bone) in local_bones.into_iter().enumerate() {
            let transforms = if let Some(parent_index) = local_bone.parent_index {
                // safety: parents are stored first, and `transforms` is written in order via
                // `enumerate`
                assert!(parent_index < i, "bones were not stored with parents first");
                let parent_transforms =
                    &unsafe { result[parent_index].assume_init_ref() }.transforms;
                if parent_transforms.is_empty() && local_bone.transforms.is_empty() {
                    vec![glam::Affine3::IDENTITY; duration.into()].into()
                } else if parent_transforms.is_empty() {
                    local_bone.transforms
                } else if local_bone.transforms.is_empty() {
                    // TODO clone!!! :O
                    parent_transforms.clone()
                } else {
                    assert_eq!(
                        parent_transforms.len(),
                        local_bone.transforms.len(),
                        "local bone transforms did not have same length as parent bone transforms"
                    );
                    parent_transforms
                        .iter()
                        .zip(local_bone.transforms.into_iter())
                        .map(|(parent, local)| *parent * local)
                        .collect()
                }
            } else if local_bone.transforms.is_empty() {
                vec![glam::Affine3::IDENTITY; duration.into()].into()
            } else {
                local_bone.transforms
            };
            let transforms = transforms
                .into_iter()
                .map(|t| t * Affine3::from_translation(local_bone.bind_position))
                .collect();
            result[i].write(Self {
                name_crc: local_bone.name_crc,
                key_bone_id: local_bone.key_bone_id,
                parent_index: local_bone.parent_index,
                bind_position: local_bone.bind_position,
                transforms,
                debug_bind_position: local_bone.debug_bind_position,
            });
        }
        unsafe { result.assume_init() }
    }

    fn from_model_bone(
        duration: Frame,
        fps: Frame,
        bone: wow_model_data::BoneAnimation,
        local_bind_position: glam::Vec3,
        debug_bind_position: glam::Vec3,
    ) -> Self {
        let key_bone_id = bone.key_bone_id();
        let name_crc = bone.bone_name_crc;
        let parent_index = bone.parent().map(usize::from);

        let translation: Option<Box<[glam::Vec3]>> = bone
            .translation
            .map(Self::snapshot_per_frame_fn(duration, fps, vector));
        let rotation: Option<Box<[glam::Quat]>> = bone
            .rotation
            .map(Self::snapshot_per_frame_fn(duration, fps, quat));
        let scale: Option<Box<[glam::Vec3]>> = bone
            .scale
            .map(Self::snapshot_per_frame_fn(duration, fps, vector));

        let transforms = if translation.is_none() && rotation.is_none() && scale.is_none() {
            Default::default()
        } else {
            Self::animation_as_transforms(
                duration,
                translation.into_iter().flatten(),
                rotation.into_iter().flatten(),
                scale.into_iter().flatten(),
            )
        };
        Self {
            key_bone_id,
            name_crc,
            parent_index,
            bind_position: local_bind_position,
            transforms,
            debug_bind_position,
        }
    }

    fn animation_as_transforms(
        duration: Frame,
        mut translations: impl Iterator<Item = glam::Vec3>,
        mut rotations: impl Iterator<Item = glam::Quat>,
        mut scales: impl Iterator<Item = glam::Vec3>,
    ) -> Box<[glam::Affine3]> {
        let mut translation_frame = translations.next();
        let mut rotation_frame = rotations.next();
        let mut scale_frame = scales.next();

        let mut transforms = Box::new_uninit_slice(duration.into());
        for i in 0..duration {
            let mut transform = glam::Affine3::IDENTITY;
            if let Some(translation) = translation_frame.take() {
                translation_frame = translations.next();
                transform *= glam::Affine3::from_translation(translation);
            };
            if let Some(rotation) = rotation_frame.take() {
                rotation_frame = rotations.next();
                transform *= glam::Affine3::from_quat(rotation);
            };
            if let Some(scale) = scale_frame.take() {
                scale_frame = scales.next();
                transform *= glam::Affine3::from_scale(scale);
            };
            transforms[usize::from(i)].write(transform);
        }
        // safety: each element was written exactly once
        // * writes between `0..duration` where `duration == transform_frames.len()`
        // * iterations do not fail, unless unexpected panic, which is unrecoverable anyway
        unsafe { transforms.assume_init() }
    }

    fn snapshot_per_frame_fn<T, U>(
        duration: Frame,
        fps: Frame,
        mapper: impl Fn(U) -> T,
    ) -> impl FnOnce(wow_model_data::AnimationValues<U>) -> Box<[T]>
    where
        T: Default + Copy + lerp::Lerp,
    {
        move |values| {
            let ValueOverTime {
                should_interpolate,
                changes,
            } = ValueOverTime::<T>::from_model_values(values, mapper);
            lerp::eval_per_frame(duration, fps, should_interpolate, changes)
        }
    }

    fn bind_position(bone: &wow_model_data::BoneAnimation) -> glam::Vec3 {
        vector(bone.pivot)
    }
}

impl From<Animation> for AnimationDefinition {
    fn from(value: Animation) -> Self {
        Self {
            duration: value.duration,
            frequency: value.frequency,
            replay_range: value.replay_range,
        }
    }
}

impl<T: Default> ValueOverTime<T> {
    fn from_model_values<U>(
        values: wow_model_data::AnimationValues<U>,
        mapper: impl Fn(U) -> T,
    ) -> Self {
        let wow_model_data::AnimationValues {
            interpolation,
            values,
            ..
        } = values;
        let should_interpolate = interpolation > 0;
        let changes = values.into_iter().map(|(k, v)| (k, mapper(v))).collect();
        ValueOverTime {
            should_interpolate,
            changes,
        }
    }
}

fn frames_from_duration(duration: u32, fps: Frame) -> Result<Frame> {
    let frames: f32 = (duration as f32) * f32::from(fps) / 1000.0;
    Ok(frames.round() as Frame)
}

fn transpose_map_entry<K, V>(result: Result<(K, Option<V>)>) -> Option<Result<(K, V)>> {
    match result {
        Ok((k, v_maybe)) => match v_maybe {
            Some(v) => Some(Ok((k, v))),
            None => None,
        },
        Err(err) => Some(Err(err)),
    }
}

impl Debug for AnimatedBone {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // no alternate form shit taking up 50000 lines...
        write!(
            f,
            "AnimatedBone{{ parent_id: {:?}, positions: {:?} }}",
            self.parent_id, self.positions
        )
    }
}
