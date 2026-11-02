use std::fmt;

#[repr(transparent)]
pub struct Flags(pub u32);

impl fmt::Debug for Flags {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:b} (0x{:x?})", self.0, self.0)
    }
}
