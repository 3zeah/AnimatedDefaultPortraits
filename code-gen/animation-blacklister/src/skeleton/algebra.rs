pub fn vector(value: wow_parse::Vector) -> glam::Vec3 {
    glam::Vec3::new(value.x, value.y, value.z)
}

pub fn quat(value: wow_parse::QuatPacked) -> glam::Quat {
    // rotation data should be normalized already: if not, something is probably wrong
    // TODO keep glam assert or add an assert here?
    glam::Quat::from_xyzw(
        value.x_unpack(),
        value.y_unpack(),
        value.z_unpack(),
        value.w_unpack(),
    )
}
