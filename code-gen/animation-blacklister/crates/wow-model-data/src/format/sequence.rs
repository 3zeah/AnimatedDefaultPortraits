use wow_parse::*;

use super::r#type::*;

#[derive(Debug)]
pub struct Sequence {
    pub animation_id: u16,
    pub variation: u16,
    pub duration: u32,
    pub move_speed: f32,
    pub flags: Flags,
    pub frequency: i16,
    pub replay_range: (u32, u32),
    pub alias_target: i16,
    pub is_primary: bool,
    pub is_alias: bool,
}

impl Sequence {
    pub fn parse<R: Parse>(r: &mut R) -> ParseResult<Self> {
        // expect stride 64
        let animation_id = r.parse_u16()?; // 2
        let variation = r.parse_u16()?; // 4
        let duration = r.parse_u32()?; // 8
        let move_speed = r.parse_f32()?; // 12
        let flags = Flags(r.parse_u32()?); // 16
        let frequency = r.parse_i16()?; // 18
        r.expect_padding(2)?; // 20
        let replay_range = (r.parse_u32()?, r.parse_u32()?); // 28
        r.skip(34)?; // 62
        let alias_target = r.parse_i16()?; // 64

        let is_primary = flags.0 & (1 << 5) != 0;
        let is_alias = flags.0 & (1 << 6) != 0;

        Ok(Sequence {
            animation_id,
            variation,
            duration,
            move_speed,
            flags,
            frequency,
            replay_range,
            alias_target,
            is_primary,
            is_alias,
        })
    }
}
