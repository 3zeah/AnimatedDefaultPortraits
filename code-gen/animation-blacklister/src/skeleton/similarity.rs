use std::collections::{HashMap, HashSet};

use log::*;

pub fn mean_skeleton_error<T>(
    a: &HashMap<u32, T>,
    b: &HashMap<u32, T>,
    error_fn: impl Fn(&T, &T) -> f32,
) -> f32 {
    let a_bones = a.keys().copied().collect::<HashSet<_>>();
    let b_bones = b.keys().copied().collect::<HashSet<_>>();
    if (a_bones.len() < 10 || b_bones.len() < 10) && a_bones.len() != b_bones.len() {
        trace!(
            "number of bones must be equal for small skeletons: {} vs {}",
            a_bones.len(),
            b_bones.len()
        );
        return f32::MAX;
    }
    let common_bones = a_bones.intersection(&b_bones).copied().collect::<Vec<_>>();
    let common_len = common_bones.len() as f32;
    let max_bone_overlap =
        (common_len / (a_bones.len() as f32)).max(common_len / (b_bones.len() as f32));
    if max_bone_overlap < 0.8 {
        trace!(
            "bone overlap too small: {} / {} vs {} / {}",
            common_len,
            a_bones.len(),
            common_len,
            b_bones.len()
        );
        return f32::MAX;
    }
    let error_sum: f32 = common_bones
        .into_iter()
        .map(|bone| {
            let a_bone = &a[&bone];
            let b_bone = &b[&bone];
            error_fn(a_bone, b_bone)
        })
        .sum::<f32>();
    error_sum / common_len
}
