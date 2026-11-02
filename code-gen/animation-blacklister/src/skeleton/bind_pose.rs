use std::collections::{HashMap, HashSet};

use super::Vec3;
use super::algebra::*;
use crate::skeleton::similarity::mean_skeleton_error;

#[derive(Debug)]
pub struct PosedBone {
    pub parent_id: Option<u32>,
    pub position: Vec3,
}

pub fn mean_error(a: &HashMap<u32, PosedBone>, b: &HashMap<u32, PosedBone>) -> f32 {
    mean_skeleton_error(a, b, |a_bone, b_bone| {
        glam::Vec3::distance_squared(a_bone.position, b_bone.position)
    })
}

pub fn bind_pose_from_model(bones: &[wow_model_data::Bone]) -> HashMap<u32, PosedBone> {
    let mut is_in_key_bone_skeleton: HashSet<usize> = HashSet::new();
    let mut skeleton = HashMap::new();
    // bones are stored in parent-first order: by iterating from the back, and marking parents
    // of key bones, the result will contain all bones that are in key-bone hierarchies
    for (i, bone) in bones.iter().enumerate().rev() {
        let bone_id_to_add = if let Some(key_bone_id) = bone.key_bone_id() {
            Some(key_bone_id)
        } else if is_in_key_bone_skeleton.contains(&i) {
            Some(bone.header.bone_name_crc)
        } else {
            None
        };
        if let Some(bone_id) = bone_id_to_add {
            let parent_id = if let Some(parent_index) = bone.parent() {
                assert!(
                    usize::from(parent_index) < i,
                    "bones were not stored with parents first"
                );
                is_in_key_bone_skeleton.insert(parent_index.into());
                Some(bones[usize::from(parent_index)].bone_id())
            } else {
                None
            };
            let bind_position = vector(bone.header.pivot);
            let posed_bone = PosedBone {
                parent_id,
                position: bind_position,
            };
            skeleton.insert(bone_id, posed_bone);
        }
    }
    skeleton
}
