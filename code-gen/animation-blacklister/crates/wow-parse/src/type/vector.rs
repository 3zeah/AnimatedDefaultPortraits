use std::fmt;

use super::super::{Parse, ParseResult};

#[derive(PartialEq, Default, Clone, Copy)]
pub struct Vector {
    pub x: f32,
    pub y: f32,
    pub z: f32,
}

impl Vector {
    pub fn dist(&self, other: &Self) -> f32 {
        f32::sqrt(self.dist_sq(other))
    }

    pub fn dist_sq(&self, other: &Self) -> f32 {
        (self.x - other.x).powi(2) + (self.y - other.y).powi(2) + (self.z - other.z).powi(2)
    }

    pub fn parse<R: Parse + ?Sized>(r: &mut R) -> ParseResult<Self> {
        let x = r.parse_f32()?;
        let y = r.parse_f32()?;
        let z = r.parse_f32()?;
        Ok(Self { x, y, z })
    }
}

impl fmt::Debug for Vector {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Vector({}, {}, {})", self.x, self.y, self.z)
    }
}
