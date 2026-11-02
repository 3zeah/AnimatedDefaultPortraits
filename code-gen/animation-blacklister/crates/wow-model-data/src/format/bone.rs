use std::collections::{BTreeMap, HashMap};
use std::fmt;

use log::trace;
use wow_parse::*;

use super::r#type::*;
use crate::Sequence;

#[derive(Default, Debug)]
pub struct Bones(pub Box<[Bone]>);

#[derive(Debug)]
pub struct Bone {
    pub header: BoneHeader,
    pub translation: Option<Track<Vector>>,
    pub rotation: Option<Track<QuatPacked>>,
    pub scale: Option<Track<Vector>>,
}

#[derive(Debug)]
pub struct BoneAnimations(pub Box<[BoneAnimation]>);

pub struct BoneAnimation {
    pub key_bone_id: i32,
    pub parent: i16,
    pub sub_mesh: u16,
    pub bone_name_crc: u32,
    pub pivot: Vector,
    pub translation: Option<AnimationValues<Vector>>,
    pub rotation: Option<AnimationValues<QuatPacked>>,
    pub scale: Option<AnimationValues<Vector>>,
}

#[derive(Debug)]
pub struct AnimationValues<T> {
    pub interpolation: u16,
    pub global_loops: i16,
    pub values: BTreeMap<u32, T>,
}

#[derive(Debug)]
pub struct BoneHeaders(pub Box<[BoneHeader]>);

#[derive(Debug)]
pub struct BoneHeader {
    pub key_bone_id: i32,
    pub flags: Flags,
    pub parent: i16,
    pub sub_mesh: u16,
    pub bone_name_crc: u32,
    pub translation: TrackHeader,
    pub rotation: TrackHeader,
    pub scale: TrackHeader,
    pub pivot: Vector,
}

pub fn parse_bone_data(
    r: &mut impl Parse,
    animation_to_load: u16,
    sequences: &[Sequence],
    header: ArrayHeader,
) -> Result<(Bones, Option<HashMap<u16, (u16, BoneAnimations)>>), ParseError> {
    trace!("begin: reading bone headers from {:?}", header);
    let bone_headers = BoneHeaders::parse(r, header)?;
    bone_headers.validate_all_data_is_ahead(r)?;
    trace!(
        "success: parse bones headers (ended at {})",
        r.offset_in_chunk()
    );
    let bone_start = bone_headers.earliest_track_data_offset();
    trace!(
        "begin: reading {} bones with track data from {:?}",
        bone_headers.0.len(),
        bone_headers.earliest_track_data_offset(),
    );
    if let Some(bone_start) = bone_start {
        r.expect_padding_until(bone_start)?;
    }
    let bones = Bones::parse(r, bone_headers)?;
    trace!("success: parse bones (ended at {})", r.offset_in_chunk());
    trace!("begin: sanity check that number of bone animations matches number of sequences");
    validate_number_of_bone_animations(sequences, &bones)?;
    trace!("success: sanity check that number of bone animations matches number of sequences");
    let loaded_animations = load_animation(r, animation_to_load, sequences, &bones)?;
    Ok((bones, loaded_animations))
}

fn load_animation(
    r: &mut impl Parse,
    animation_to_load: u16,
    sequences: &[Sequence],
    bones: &Bones,
) -> Result<Option<HashMap<u16, (u16, BoneAnimations)>>, ParseError> {
    let animation_variation_index: HashMap<u16, u16> = sequences
        .iter()
        .enumerate()
        .filter_map(|(i, a)| {
            if a.animation_id == animation_to_load {
                Some((
                    a.variation,
                    u16::try_from(i).expect("number of sequences out of range"),
                ))
            } else {
                None
            }
        })
        .collect();
    if animation_variation_index.is_empty() {
        trace!("model had no animation for {animation_to_load}: animation will not be loaded");
        Ok(None)
    } else {
        let mut loaded_animations = HashMap::with_capacity(animation_variation_index.len());
        for (variation, bone_index) in animation_variation_index {
            trace!(
                "loading bone animations for animation {animation_to_load}, variation {variation}: \
                {bone_index}"
            );
            let bone_animations = bones.load_animations(r, bone_index)?;
            loaded_animations.insert(variation, (bone_index, bone_animations));
        }
        trace!(
            "success: loaded bone animations for each variation of {animation_to_load}: \
            {loaded_animations:#?}"
        );
        Ok(Some(loaded_animations))
    }
}

impl Bones {
    pub fn load_animations<R: Parse>(&self, r: &mut R, index: u16) -> ParseResult<BoneAnimations> {
        let animations: Box<[BoneAnimation]> = self
            .0
            .iter()
            .map(|bone| bone.load_animation(r, index))
            .collect::<Result<_, _>>()?;
        Ok(BoneAnimations(animations))
    }

    pub fn parse<R: Parse>(r: &mut R, headers: BoneHeaders) -> ParseResult<Self> {
        let len = headers.0.len() as usize;
        let mut slice: Box<[std::mem::MaybeUninit<Bone>]> = Box::new_uninit_slice(len);
        let mut i = 0;
        for header in headers.0 {
            let value = match Bone::parse(r, header) {
                Ok(ok) => ok,
                // MaybeUninit does not drop values: in the case of error, drop previous values
                Err(e) => {
                    for j in 0..i {
                        unsafe { slice[j].assume_init_drop() };
                    }
                    return Err(e);
                }
            };
            slice[i].write(value);
            i += 1;
        }
        // safety: wrote to each index exactly once
        Ok(Bones(unsafe { slice.assume_init() }))
    }
}

impl Bone {
    pub fn bone_id(&self) -> u32 {
        self.header.bone_id()
    }

    pub fn key_bone_id(&self) -> Option<u32> {
        self.header.key_bone_id()
    }

    pub fn parent(&self) -> Option<u16> {
        self.header.parent()
    }

    pub fn load_animation<R: Parse>(&self, r: &mut R, index: u16) -> ParseResult<BoneAnimation> {
        let translation = self
            .translation
            .as_ref()
            .map(|t| Self::load_animation_values(r, index, t, Parse::parse_vector))
            .transpose()?
            .filter(|timeline| !timeline.values.is_empty());
        let rotation = self
            .rotation
            .as_ref()
            .map(|t| Self::load_animation_values(r, index, t, Parse::parse_quat_packed))
            .transpose()?
            .filter(|timeline| !timeline.values.is_empty());
        let scale = self
            .scale
            .as_ref()
            .map(|t| Self::load_animation_values(r, index, t, Parse::parse_vector))
            .transpose()?
            .filter(|timeline| !timeline.values.is_empty());
        Ok(BoneAnimation {
            key_bone_id: self.header.key_bone_id,
            parent: self.header.parent,
            sub_mesh: self.header.sub_mesh,
            bone_name_crc: self.header.bone_name_crc,
            pivot: self.header.pivot,
            translation,
            rotation,
            scale,
        })
    }

    pub fn parse<R: Parse>(r: &mut R, header: BoneHeader) -> ParseResult<Self> {
        let translation = Track::parse(r, header.translation)?;
        let rotation = Track::parse(r, header.rotation)?;
        let scale = Track::parse(r, header.scale)?;
        Ok(Self {
            header,
            translation,
            rotation,
            scale,
        })
    }

    fn load_animation_values<R: Parse, T, F>(
        r: &mut R,
        index: u16,
        track: &Track<T>,
        value_parser: F,
    ) -> ParseResult<AnimationValues<T>>
    where
        F: Fn(&mut R) -> ParseResult<T>,
    {
        let values = track.load(r, index, value_parser)?;
        Ok(AnimationValues {
            interpolation: track.interpolation,
            global_loops: track.global_loops,
            values,
        })
    }
}

impl BoneAnimation {
    pub fn key_bone_id(&self) -> Option<u32> {
        let id = self.key_bone_id;
        if id.is_negative() {
            None
        } else {
            // `as` safety: id is not negative
            Some(id as u32)
        }
    }

    pub fn pivot(&self) -> Vector {
        self.pivot
    }

    pub fn parent(&self) -> Option<u16> {
        // -1 = no parent
        u16::try_from(self.parent).ok()
    }

    pub fn is_empty(&self) -> bool {
        self.rotation.is_none() && self.scale.is_none() && self.rotation.is_none()
    }
}

impl BoneHeaders {
    pub fn earliest_track_data_offset(&self) -> Option<u32> {
        self.0
            .iter()
            .map(BoneHeader::earliest_track_data_offset)
            .flat_map(Option::into_iter)
            .min()
    }

    pub fn validate_all_data_is_ahead<R: Parse>(&self, r: &mut R) -> ParseResult<()> {
        for header in &self.0 {
            header.validate_all_data_is_ahead(r)?
        }
        Ok(())
    }

    pub fn parse<R: Parse>(r: &mut R, header: ArrayHeader) -> ParseResult<Self> {
        let bones = r.parse_array_from_header(header, BoneHeader::parse)?;
        Ok(Self(bones))
    }
}

impl BoneHeader {
    pub fn bone_id(&self) -> u32 {
        self.key_bone_id().unwrap_or(self.bone_name_crc)
    }

    pub fn key_bone_id(&self) -> Option<u32> {
        Some(self.key_bone_id)
            .map(u32::try_from)
            .and_then(Result::ok)
    }

    pub fn parent(&self) -> Option<u16> {
        // -1 = no parent
        u16::try_from(self.parent).ok()
    }

    pub fn earliest_track_data_offset(&self) -> Option<u32> {
        [
            self.translation.earliest_offset(),
            self.rotation.earliest_offset(),
            self.scale.earliest_offset(),
        ]
        .into_iter()
        .flat_map(Option::into_iter)
        .min()
    }

    pub fn validate_all_data_is_ahead<R: Parse>(&self, r: &mut R) -> ParseResult<()> {
        self.translation.validate_all_data_is_ahead(r)?;
        self.rotation.validate_all_data_is_ahead(r)?;
        self.scale.validate_all_data_is_ahead(r)?;
        Ok(())
    }

    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        // expect stride 88
        let key_bone_id = r.parse_i32()?; // 4
        let flags = Flags(r.parse_u32()?); // 8
        let parent = r.parse_i16()?; // 10
        let sub_mesh = r.parse_u16()?; // 12
        let bone_name_crc = r.parse_u32()?; // 16

        let translation = TrackHeader::parse(r)?; // 36
        let rotation = TrackHeader::parse(r)?; // 56
        let scale = TrackHeader::parse(r)?; // 76
        let pivot = Vector::parse(r)?; // 88

        {
            trace!("key_bone_id = {key_bone_id}");
            trace!("flags = {flags:?}");
            trace!("parent = {parent}");
            trace!("sub_mesh = {sub_mesh}");
            trace!("bone_name_crc = {bone_name_crc}");
            trace!("translation = {translation:?}");
            trace!("rotation = {rotation:?}");
            trace!("scale = {scale:?}");
            trace!("pivot = {pivot:?}");

            trace!("{} <- end of bone header", r.offset_in_chunk());
        }

        Ok(Self {
            key_bone_id,
            flags,
            parent,
            sub_mesh,
            bone_name_crc,
            translation,
            rotation,
            scale,
            pivot,
        })
    }
}

fn validate_number_of_bone_animations(
    sequences: &[crate::Sequence],
    bones: &Bones,
) -> ParseResult<()> {
    let sequence_count = sequences.len();
    for bone in &bones.0 {
        if let Some(translation) = &bone.translation
            && translation.len() != 1
            && translation.len() != sequence_count
        {
            parse_bail!(
                "expected number of translation animations in bone track to be singleton or equal \
                to number of sequences, {}, but was {}: {:#?}",
                sequence_count,
                translation.len(),
                bone
            )
        }
        if let Some(rotation) = &bone.rotation
            && rotation.len() != 1
            && rotation.len() != sequence_count
        {
            parse_bail!(
                "expected number of rotation animations in bone track to be singleton or equal \
                to number of sequences, {}, but was {}: {:#?}",
                sequence_count,
                rotation.len(),
                bone
            )
        }
        if let Some(scale) = &bone.scale
            && scale.len() != 1
            && scale.len() != sequence_count
        {
            parse_bail!(
                "expected number of scale animations in bone track to be singleton or equal \
                to number of sequences, {}, but was {}: {:#?}",
                sequence_count,
                scale.len(),
                bone
            )
        }
    }
    Ok(())
}

impl fmt::Debug for BoneAnimation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_empty() {
            return f
                .debug_struct("BoneAnimation")
                .field("key_bone_id", &self.key_bone_id)
                .field("parent", &self.parent)
                .field("sub_mesh", &self.sub_mesh)
                .field("bone_name_crc", &self.bone_name_crc)
                .field("pivot", &self.pivot)
                .finish();
        }
        f.debug_struct("BoneAnimation")
            .field("key_bone_id", &self.key_bone_id)
            .field("parent", &self.parent)
            .field("sub_mesh", &self.sub_mesh)
            .field("bone_name_crc", &self.bone_name_crc)
            .field("pivot", &self.pivot)
            .field("translation", &self.translation)
            .field("rotation", &self.rotation)
            .field("scale", &self.scale)
            .finish()
    }
}
