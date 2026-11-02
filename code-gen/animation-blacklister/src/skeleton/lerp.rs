use std::collections::BTreeMap;

use super::Frame;

pub trait Lerp {
    fn lerp(prev: Self, next: Self, t: f32) -> Self;
}

pub fn eval_per_frame<T>(
    duration: Frame,
    fps: Frame,
    should_interpolate: bool,
    values: BTreeMap<u32, T>,
) -> Box<[T]>
where
    T: Default + Copy + Lerp,
{
    let mut value_over_time_iterator = values.iter();
    let mut prev_change: (u32, T) = value_over_time_iterator
        .next()
        .map(copy_tuple)
        .unwrap_or_default();

    let mut result = Box::new_uninit_slice(duration.into());
    result[0].write(prev_change.1);
    // for each frame in the animation, maintain a sliding window of the previous and next value
    // change, and define the frame value by linear interpolation
    let mut next_change_maybe = value_over_time_iterator.next().map(copy_tuple);
    for frame in 1..duration {
        let t = 1000.0 * f32::from(frame) / f32::from(fps);
        // slide window until the frame is inside of it
        while let Some(next_change) = next_change_maybe
            && t >= (next_change.0 as f32)
        {
            prev_change = next_change;
            next_change_maybe = value_over_time_iterator.next().map(copy_tuple);
        }
        // there is a next value ==> interpolate between that and the previous
        let value: T = if should_interpolate && let Some(next_change) = next_change_maybe {
            // interpolate frame value between the change-window values
            lerp(prev_change, next_change, t)
        } else {
            // repeat value if not interpolating, or if this is a final-value suffix
            prev_change.1
        };
        result[usize::from(frame)].write(value.into());
    }
    // safety: each element was written exactly once
    // * writes to `0` and then between `1..duration` where `duration == transform_frames.len()`
    // * iterations do not fail, unless unexpected panic, which is unrecoverable anyway
    unsafe { result.assume_init() }
}

fn lerp<T: Lerp>(prev: (u32, T), next: (u32, T), t: f32) -> T {
    let (prev_t, prev_v) = prev;
    let (next_t, next_v) = next;
    let t_norm = (t - (prev_t as f32)) / ((next_t - prev_t) as f32);
    let out = Lerp::lerp(prev_v, next_v, t_norm);
    out
}

fn copy_tuple<K: Copy, V: Copy>(value: (&K, &V)) -> (K, V) {
    (*value.0, *value.1)
}

impl Lerp for glam::Vec3 {
    fn lerp(prev: Self, next: Self, t: f32) -> Self {
        Self::lerp(prev, next, t)
    }
}

impl Lerp for glam::Quat {
    fn lerp(prev: Self, next: Self, t: f32) -> Self {
        Self::slerp(prev, next, t)
    }
}
