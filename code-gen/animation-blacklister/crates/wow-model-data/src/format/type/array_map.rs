use std::fmt;

#[derive(Default)]
#[repr(transparent)]
pub struct ArrayMap<T>(pub Box<[T]>);

impl<T> From<Box<[T]>> for ArrayMap<T> {
    fn from(value: Box<[T]>) -> Self {
        ArrayMap(value)
    }
}

impl<T: fmt::Display> fmt::Debug for ArrayMap<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut i: usize = 0;
        write!(f, "{{ ")?;
        for v in &self.0 {
            if i > 0 {
                write!(f, ", ")?;
            }
            write!(f, "{i}: {v}")?;
            i += 1;
        }
        write!(f, " }}")?;
        Ok(())
    }
}
