#[cfg(not(windows))]
#[macro_export]
macro_rules! separator {
    () => {
        "/"
    };
}

#[cfg(windows)]
#[macro_export]
macro_rules! separator {
    () => {
        r#"\"#
    };
}

#[macro_export]
macro_rules! path_str {
    ($arg:expr) => {
        $arg
    };
    ($first:expr,  $($tail:expr),+) => {
        concat!($first, $crate::separator!(), $crate::path_str!($($tail),+))
    };
}
