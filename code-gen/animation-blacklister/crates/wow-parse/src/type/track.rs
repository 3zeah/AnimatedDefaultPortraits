use std::cmp::min;
use std::collections::BTreeMap;
use std::fmt;
use std::marker::PhantomData;

use log::trace;

use crate::*;

/// reference to a set of value timelines
///
/// each value timeline is defined as an ordered set of timestamp-tagged values, and each timeline
/// may be [Self::load]:ed by index
///
/// for example, and in particular, tracks in world of warcraft define the animation of a bone: each
/// bone has a track for each type of transform (translation, rotation, scale), and the track is
/// indexed by the animation index of the model. to play animation with index 2, then, the caller
/// may [Self::load] index 2 of the track and step through the transform timeline at each tick
#[derive(Default)]
pub struct Track<T> {
    pub interpolation: u16,
    pub global_loops: i16,
    pub timestamps: Box<[ArrayHeader]>,
    pub values: Box<[ArrayHeader]>,
    _t: PhantomData<T>,
}

/// reference to a [Track] along with some extra data
#[derive(Clone, Copy)]
pub struct TrackHeader {
    pub interpolation: u16,
    pub global_sequence: i16,
    pub timestamps: ArrayHeader,
    pub values: ArrayHeader,
}

#[derive(PartialEq, Eq)]
pub struct SplineKey<T> {
    pub value: T,
    pub tan_in: T,
    pub tan_out: T,
}

impl<T> Track<T> {
    pub fn load<R: Parse, F>(
        &self,
        r: &mut R,
        index: u16,
        value_parser: F,
    ) -> ParseResult<BTreeMap<u32, T>>
    where
        F: Fn(&mut R) -> ParseResult<T>,
    {
        let timestamps_header = Self::get_data_array(&self.timestamps, index)?;
        let values_header = Self::get_data_array(&self.values, index)?;
        let timestamps = r.parse_array_from_header(timestamps_header, Parse::parse_u32)?;
        let values = r.parse_array_from_header(values_header, value_parser)?;
        if timestamps.len() != values.len() {
            parse_bail!(
                "number of timestamps in track, {}, did not match number of values, {}",
                timestamps.len(),
                values.len()
            );
        }
        Ok(timestamps.into_iter().zip(values).collect())
    }

    pub fn len(&self) -> usize {
        self.timestamps.len()
    }

    pub fn parse<R: Parse>(r: &mut R, header: TrackHeader) -> ParseResult<Option<Track<T>>> {
        if header.is_empty() {
            return Ok(None);
        }
        let timestamps: Box<[ArrayHeader]> =
            Self::parse_component(r, "timestamp", header.timestamps)?;
        let values: Box<[ArrayHeader]> = Self::parse_component(r, "value", header.values)?;
        Ok(Some(Track {
            interpolation: header.interpolation,
            global_loops: header.global_sequence,
            timestamps,
            values,
            _t: PhantomData,
        }))
    }

    fn get_data_array(arrays: &Box<[ArrayHeader]>, index: u16) -> ParseResult<ArrayHeader> {
        // singleton arrays signal static value
        if arrays.len() == 1 {
            return Ok(arrays[0]);
        }
        Ok(*arrays.get(usize::from(index)).ok_or(parse_error!(
            "index {index} out of range for track of length {}",
            arrays.len()
        ))?)
    }

    fn parse_component<R: Parse>(
        r: &mut R,
        component_name: &str,
        header: ArrayHeader,
    ) -> ParseResult<Box<[ArrayHeader]>> {
        if header.is_empty() {
            return Ok(Default::default());
        }
        trace!("reading {component_name} tracks from {header:?}");
        let output = r.parse_array_from_header(header, ArrayHeader::parse)?;
        trace!(
            "done: reading {component_name} tracks (ended at {})",
            r.offset_in_chunk()
        );
        Ok(output)
    }
}

impl TrackHeader {
    pub fn earliest_offset(&self) -> Option<u32> {
        if self.is_empty() {
            return None;
        }
        Some(min(self.timestamps.offset(), self.values.offset()))
    }

    pub fn is_empty(&self) -> bool {
        // it should not be the case that these lengths differ, and it is upheld by the parse
        // function, but whatever
        self.timestamps.is_empty() && self.values.is_empty()
    }

    pub fn validate_all_data_is_ahead<R: Parse>(&self, r: &mut R) -> ParseResult<()> {
        self.timestamps.validate_all_data_is_ahead(r)?;
        self.values.validate_all_data_is_ahead(r)?;
        Ok(())
    }

    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        let interpolation = r.parse_u16()?;
        let global_sequence = r.parse_i16()?;
        let timestamps = r.parse_array_header()?;
        let values = r.parse_array_header()?;
        if timestamps.len() != values.len() {
            parse_bail!(
                "number of timestamps in track, {}, did not match number of values, {}",
                timestamps.len(),
                values.len()
            );
        }
        Ok(Self {
            interpolation,
            global_sequence,
            timestamps,
            values,
        })
    }
}

impl<T> SplineKey<T> {
    pub fn parser<R: Parse, F>(value_parser: &F) -> impl Fn(&mut R) -> ParseResult<Self>
    where
        F: Fn(&mut R) -> ParseResult<T>,
    {
        move |r| Self::parse(r, value_parser)
    }

    pub fn parse<R: Parse, F>(r: &mut R, value_parser: F) -> ParseResult<Self>
    where
        F: Fn(&mut R) -> ParseResult<T>,
    {
        let value = value_parser(r)?;
        let tan_in = value_parser(r)?;
        let tan_out = value_parser(r)?;
        Ok(Self {
            value,
            tan_in,
            tan_out,
        })
    }
}

impl<T> fmt::Debug for Track<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        writeln!(f, "Track {{")?;
        write!(f, "  timestamps: ")?;
        write_debug_headers_component(f, &self.timestamps)?;
        writeln!(f, ",")?;
        write!(f, "      values: ")?;
        write_debug_headers_component(f, &self.values)?;
        writeln!(f, ",")?;
        write!(f, "}}")?;
        Ok(())
    }
}

impl fmt::Debug for TrackHeader {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.is_empty() {
            return write!(f, "(empty TrackHeader)");
        }
        let mut builder = f.debug_struct("TrackHeader");
        builder
            .field("interpolation", &self.interpolation)
            .field("global_sequence", &self.global_sequence);
        if !self.timestamps.is_empty() {
            builder.field("timestamps", &self.timestamps);
        }
        if !self.values.is_empty() {
            builder.field("values", &self.values);
        }
        builder.finish()
    }
}

impl<T: fmt::Debug> fmt::Debug for SplineKey<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "SplineKey({:?}, in: {:?}, out: {:?})",
            self.value, self.tan_in, self.tan_out
        )
    }
}

fn write_debug_headers_component(
    f: &mut fmt::Formatter<'_>,
    headers: &Box<[ArrayHeader]>,
) -> fmt::Result {
    if headers.is_empty() {
        return write!(f, "{{}}");
    }
    write!(f, "{{ ")?;
    let mut i: usize = 0;
    let mut is_first_write = true;
    for animation_header in headers {
        if animation_header.offset() != 0 || animation_header.len() != 0 {
            if is_first_write {
                is_first_write = false;
            } else {
                write!(f, ", ")?;
            }
            write!(f, "{i}: {animation_header:?}")?;
        }
        i += 1;
    }
    write!(f, " }}")?;
    Ok(())
}
