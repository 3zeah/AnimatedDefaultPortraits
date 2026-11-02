use std::fmt;

use super::super::{Parse, ParseResult};

#[derive(PartialEq, Clone, Copy)]
pub struct Quat {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

#[derive(PartialEq, Eq, Clone, Copy)]
pub struct QuatPacked {
    pub x: u16,
    pub y: u16,
    pub z: u16,
    pub w: u16,
}

impl Quat {
    pub fn ang_dist(&self, other: &Self) -> f32 {
        let dot = (self.x * other.x) + (self.y * other.y) + (self.z * other.z) + (self.w * other.w);
        2.0 * f32::acos(dot.clamp(-1.0, 1.0))
    }
}

impl QuatPacked {
    pub fn unpack(&self) -> Quat {
        Quat {
            x: self.x_unpack(),
            y: self.y_unpack(),
            z: self.z_unpack(),
            w: self.w_unpack(),
        }
    }

    pub fn x_unpack(&self) -> f32 {
        component_as_float(self.x)
    }

    pub fn y_unpack(&self) -> f32 {
        component_as_float(self.y)
    }

    pub fn z_unpack(&self) -> f32 {
        component_as_float(self.z)
    }

    pub fn w_unpack(&self) -> f32 {
        component_as_float(self.w)
    }

    pub fn parse<R: Parse + ?Sized>(r: &mut R) -> ParseResult<Self> {
        let x = r.parse_u16()?;
        let y = r.parse_u16()?;
        let z = r.parse_u16()?;
        let w = r.parse_u16()?;
        Ok(Self { x, y, z, w })
    }
}

fn component_as_float(value: u16) -> f32 {
    // TODO i16:MAX sent here is >1...
    (f32::from(value) / f32::from(i16::MAX)) - 1f32
}

impl From<QuatPacked> for Quat {
    fn from(value: QuatPacked) -> Self {
        value.unpack()
    }
}

impl Default for Quat {
    fn default() -> Self {
        Self {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            w: 1.0,
        }
    }
}

impl Default for QuatPacked {
    fn default() -> Self {
        const ZERO: u16 = i16::MAX as u16;
        const ONE: u16 = u16::MAX - 1;
        Self {
            x: ZERO,
            y: ZERO,
            z: ZERO,
            w: ONE,
        }
    }
}

impl fmt::Debug for Quat {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "QuatPacked{{ x: {}, y: {}, z: {}, w: {} }}",
            self.x, self.y, self.z, self.w
        )
    }
}

impl fmt::Debug for QuatPacked {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "QuatPacked{{ x: {}, y: {}, z: {}, w: {} }}",
            self.x, self.y, self.z, self.w
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unpacked_default_is_identity_rotation() {
        let actual = QuatPacked::default();
        let actual_unpacked = (
            actual.x_unpack(),
            actual.y_unpack(),
            actual.z_unpack(),
            actual.w_unpack(),
        );
        assert_eq!((0f32, 0f32, 0f32, 1f32), actual_unpacked)
    }

    #[test]
    fn from_packed_default_is_equal_to_default() {
        let actual: Quat = QuatPacked::default().into();
        assert_eq!(Quat::default(), actual)
    }
}
