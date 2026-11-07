use std::collections::BTreeMap;

use log::*;
use wow_parse::*;

#[derive(Default, Debug)]
pub struct Cameras(pub Box<[Camera]>);

#[derive(Debug)]
pub struct Camera {
    pub header: CameraHeader,
    pub position: Option<Track<SplineKey<Vector>>>,
    pub target: Option<Track<SplineKey<Vector>>>,
    pub roll: Option<Track<SplineKey<f32>>>,
    pub fov_diagonal: Option<Track<SplineKey<f32>>>,
}
#[derive(Debug)]

pub struct CameraAnimation {
    pub header: CameraHeader,
    pub position: Option<BTreeMap<u32, SplineKey<Vector>>>,
    pub target: Option<BTreeMap<u32, SplineKey<Vector>>>,
    pub roll: Option<BTreeMap<u32, SplineKey<f32>>>,
    pub fov_diagonal: Option<BTreeMap<u32, SplineKey<f32>>>,
}

#[derive(Debug)]
pub struct CameraHeaders(pub Box<[CameraHeader]>);

#[derive(Clone, Copy, Debug)]
pub struct CameraHeader {
    pub camera_type: u32,
    pub far_clip: f32,
    pub near_clip: f32,
    pub position_track: TrackHeader,
    pub position: Vector,
    pub target_track: TrackHeader,
    pub target: Vector,
    pub roll: TrackHeader,
    pub fov: TrackHeader,
}

pub fn parse_camera_data(
    r: &mut impl Parse,
    header: ArrayHeader,
) -> Result<(Cameras, Option<CameraAnimation>, Option<CameraAnimation>), ParseError> {
    trace!("begin: reading camera headers from {:?}", header);
    let camera_headers = CameraHeaders::parse(r, header)?;
    camera_headers.validate_all_data_is_ahead(r)?;
    trace!(
        "success: parse camera headers (ended at {})",
        r.offset_in_chunk()
    );
    let camera_start = camera_headers.earliest_track_data_offset();
    trace!(
        "begin: reading {} cameras with track data from {:?}",
        camera_headers.0.len(),
        camera_headers.earliest_track_data_offset(),
    );
    if let Some(camera_start) = camera_start {
        r.expect_padding_until(camera_start)?;
    }
    let cameras = Cameras::parse(r, camera_headers)?;
    trace!("success: parse cameras (ended at {})", r.offset_in_chunk());
    const PORTRAIT_CAMERA: u32 = 0;
    const CHARACTER_INFO_CAMERA: u32 = 1;
    let portrait_values: Option<CameraAnimation> = cameras.load_animation(r, PORTRAIT_CAMERA)?;
    trace!("success: loaded portrait camera values: {portrait_values:#?}");
    let character_info_values = cameras.load_animation(r, CHARACTER_INFO_CAMERA)?;
    trace!("success: loaded character-info camera values: {character_info_values:#?}");
    Ok((cameras, portrait_values, character_info_values))
}

impl Cameras {
    pub fn load_animation<R: Parse>(
        &self,
        r: &mut R,
        camera_type_to_load: u32,
    ) -> ParseResult<Option<CameraAnimation>> {
        for camera in &self.0 {
            if camera.header.camera_type == camera_type_to_load {
                return Ok(Some(camera.load_animation(r, 0)?));
            }
        }
        Ok(None)
    }

    pub fn parse<R: Parse>(r: &mut R, headers: CameraHeaders) -> ParseResult<Self> {
        let len = headers.0.len() as usize;
        let mut slice: Box<[std::mem::MaybeUninit<Camera>]> = Box::new_uninit_slice(len);
        let mut i = 0;
        for header in headers.0 {
            let value = match Camera::parse(r, header) {
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
        Ok(Self(unsafe { slice.assume_init() }))
    }
}

impl Camera {
    pub fn load_animation<R: Parse>(&self, r: &mut R, index: u16) -> ParseResult<CameraAnimation> {
        let position = self
            .position
            .as_ref()
            .map(|t| t.load(r, index, SplineKey::parser(&Parse::parse_vector)))
            .transpose()?
            .filter(|timeline| !timeline.is_empty());
        let target = self
            .target
            .as_ref()
            .map(|t| t.load(r, index, SplineKey::parser(&Parse::parse_vector)))
            .transpose()?
            .filter(|timeline| !timeline.is_empty());
        let roll = self
            .roll
            .as_ref()
            .map(|t| t.load(r, index, SplineKey::parser(&Parse::parse_f32)))
            .transpose()?
            .filter(|timeline| !timeline.is_empty());
        let fov = self
            .fov_diagonal
            .as_ref()
            .map(|t| t.load(r, index, SplineKey::parser(&Parse::parse_f32)))
            .transpose()?
            .filter(|timeline| !timeline.is_empty());
        Ok(CameraAnimation {
            header: self.header,
            position,
            target,
            roll,
            fov_diagonal: fov,
        })
    }

    pub fn parse<R: Parse>(r: &mut R, header: CameraHeader) -> ParseResult<Self> {
        let position: Option<Track<_>> = Track::parse(r, header.position_track)?;
        let target = Track::parse(r, header.target_track)?;
        let roll = Track::parse(r, header.roll)?;
        let fov = Track::parse(r, header.fov)?;
        Ok(Self {
            header,
            position,
            target,
            roll,
            fov_diagonal: fov,
        })
    }
}

impl CameraHeaders {
    pub fn earliest_track_data_offset(&self) -> Option<u32> {
        self.0
            .iter()
            .map(CameraHeader::earliest_track_data_offset)
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
        let bones = r.parse_array_from_header(header, CameraHeader::parse)?;
        Ok(Self(bones))
    }
}

impl CameraHeader {
    pub fn earliest_track_data_offset(&self) -> Option<u32> {
        [
            self.position_track.earliest_offset(),
            self.target_track.earliest_offset(),
            self.roll.earliest_offset(),
            self.fov.earliest_offset(),
        ]
        .into_iter()
        .flat_map(Option::into_iter)
        .min()
    }

    pub fn validate_all_data_is_ahead<R: Parse>(&self, r: &mut R) -> ParseResult<()> {
        self.position_track.validate_all_data_is_ahead(r)?;
        self.target_track.validate_all_data_is_ahead(r)?;
        self.roll.validate_all_data_is_ahead(r)?;
        self.fov.validate_all_data_is_ahead(r)?;
        Ok(())
    }

    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        // expect stride 116
        let camera_type = r.parse_u32()?; // 4
        let far_clip = r.parse_f32()?; // 8
        let near_clip = r.parse_f32()?; // 12
        let position_track = TrackHeader::parse(r)?; // 32
        let position = r.parse_vector()?; // 44
        let target_track = TrackHeader::parse(r)?; // 64
        let target = r.parse_vector()?; // 76
        let roll = TrackHeader::parse(r)?; // 96
        let fov = TrackHeader::parse(r)?; // 116

        {
            trace!("camera_type = {camera_type}");
            trace!("far_clip = {far_clip}");
            trace!("near_clip = {near_clip}");
            trace!("position_track = {position_track:?}");
            trace!("position = {position:?}");
            trace!("target_track = {target_track:?}");
            trace!("target = {target:?}");
            trace!("roll = {roll:?}");
            trace!("fov = {fov:?}");

            trace!("{} <- end of camera header", r.offset_in_chunk());
        }

        Ok(Self {
            camera_type,
            far_clip,
            near_clip,
            position_track,
            position,
            target_track,
            target,
            roll,
            fov,
        })
    }
}
