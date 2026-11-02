use std::fs;
use std::path::Path;
use std::time::Duration;

const CACHE_LIFETIME: Duration = Duration::from_hours(7 * 24);

pub enum FileCacheValidity {
    Valid { days: Option<u64> },
    StaleInCache { days: u64 },
    NotInCache,
}

pub fn check_file_cache(path: impl AsRef<Path>) -> Result<FileCacheValidity, std::io::Error> {
    let path = path.as_ref();
    if !fs::exists(path)? {
        return Ok(FileCacheValidity::NotInCache);
    }
    if let Ok(modified) = fs::metadata(path)?.modified()
        && let Ok(elapsed) = modified.elapsed()
    {
        let cache_is_current = elapsed <= CACHE_LIFETIME;
        let elapsed_days = elapsed.as_secs() / (24 * 60 * 60);
        if cache_is_current {
            return Ok(FileCacheValidity::Valid {
                days: Some(elapsed_days),
            });
        } else {
            return Ok(FileCacheValidity::StaleInCache { days: elapsed_days });
        }
    }
    // "last modified" metadata is not available somehow... let the user handle the cache
    return Ok(FileCacheValidity::Valid { days: None });
}
