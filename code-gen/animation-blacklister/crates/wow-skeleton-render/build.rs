use std::path::Path;

fn main() {
    let config_file = Path::new("config.ron");
    if config_file.is_file() {
        return;
    }
    eprintln!(
        r#"config not present: adding default config as "{}""#,
        config_file.to_string_lossy()
    );
    std::fs::copy(Path::new("config_default.ron"), config_file)
        .expect("failed to copy default config during build");
}
