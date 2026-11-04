use std::path::Path;
use std::sync::{LazyLock, RwLock};

pub use log::{Level, debug, error, info, trace, warn};
use log::{LevelFilter, Record};
use log4rs::append::console::{ConsoleAppender, Target};
use log4rs::append::rolling_file::RollingFileAppender;
use log4rs::append::rolling_file::policy::compound::CompoundPolicy;
use log4rs::append::rolling_file::policy::compound::roll::fixed_window::FixedWindowRoller;
use log4rs::append::rolling_file::policy::compound::trigger::onstartup::OnStartUpTrigger;
use log4rs::append::rolling_file::policy::compound::trigger::size::SizeTrigger;
use log4rs::config::{Appender, Config, Root};
use log4rs::encode::pattern::PatternEncoder;
use log4rs::filter::threshold::ThresholdFilter;
use log4rs::filter::{Filter, Response};

static DYNAMIC_FILTERS: LazyLock<RwLock<DynamicFilters>> =
    LazyLock::new(|| RwLock::new(DynamicFilters::new()));

pub struct FilterHandle {
    i: usize,
}

pub fn add_target_filter(level: Level, target: &'static str) -> FilterHandle {
    add_filter(TargetFilter { level, target })
}

impl FilterHandle {
    pub fn remove(self) {
        drop(self)
    }
}

/// * print `Info` to stderr
/// * _info.log_ holds `Info` of previous session, and previous previous in _info.0.log_, to access
/// the previous session even while current session is logging
/// * _trace.log_ is continually appended with everything (`Trace`), and keeps archive files (each
/// log file needs to be small to facilitate fast loads and tooling support)
pub fn init<P: AsRef<Path>>(log_dir: P) {
    const INFO_PATTERN: &str = "{d(%Y-%m-%d %H:%M:%S)} {h({l:>5} {t})} - {m}{n}";
    const TRACE_PATTERN: &str = "{d(%Y-%m-%dT%H:%M:%S%.f):0<29}{d(%:z)} {l:>5} {t} - {m}{n}";
    const MAX_FILE_SIZE: u64 = 1024 * 1024;
    const TRACE_FILE_COUNT: u32 = 10;

    let log_path = log_dir.as_ref();

    let _ = LazyLock::force(&DYNAMIC_FILTERS);

    // rotate info file each start
    let info_policy = {
        let trigger = OnStartUpTrigger::new(0);
        let archive_path_pattern = Path::join(log_path, "info.{}.log");
        let archive_path_pattern_str = archive_path_pattern.to_str().expect("path pattern error");
        let roller = FixedWindowRoller::builder()
            .build(archive_path_pattern_str, 1)
            .expect("log init error");
        CompoundPolicy::new(Box::new(trigger), Box::new(roller))
    };
    // rotate trace files when too big
    let trace_policy = {
        let trigger = SizeTrigger::new(MAX_FILE_SIZE);
        let archive_path_pattern = Path::join(log_path, "trace.{}.log");
        let archive_path_pattern_str = archive_path_pattern.to_str().expect("path pattern error");
        let roller = FixedWindowRoller::builder()
            .build(archive_path_pattern_str, TRACE_FILE_COUNT)
            .expect("log init error");
        CompoundPolicy::new(Box::new(trigger), Box::new(roller))
    };

    let stderr_appender = ConsoleAppender::builder()
        .encoder(Box::new(PatternEncoder::new(INFO_PATTERN)))
        .target(Target::Stderr)
        .build();
    let info_file_appender = RollingFileAppender::builder()
        .encoder(Box::new(PatternEncoder::new(INFO_PATTERN)))
        .build(Path::join(log_path, "info.log"), Box::new(info_policy))
        .expect("log init error");
    let trace_file_appender = RollingFileAppender::builder()
        .encoder(Box::new(PatternEncoder::new(TRACE_PATTERN)))
        .build(Path::join(log_path, "trace.log"), Box::new(trace_policy))
        .expect("log init error");

    let config = Config::builder()
        .appender(
            Appender::builder()
                .filter(Box::new(ThresholdFilter::new(LevelFilter::Info)))
                .filter(Box::new(DynamicFilter {}))
                .build("stderr", Box::new(stderr_appender)),
        )
        .appender(
            Appender::builder()
                .filter(Box::new(ThresholdFilter::new(LevelFilter::Info)))
                .filter(Box::new(DynamicFilter {}))
                .build("info", Box::new(info_file_appender)),
        )
        .appender(
            Appender::builder()
                .filter(Box::new(DynamicFilter {}))
                .build("trace", Box::new(trace_file_appender)),
        )
        .build(
            Root::builder()
                .appender("stderr")
                .appender("info")
                .appender("trace")
                .build(LevelFilter::Trace),
        )
        .expect("log init error");
    log4rs::init_config(config).expect("log init error");
    info!("log start");
}

#[derive(Debug)]
struct DynamicFilter {}

#[derive(Default, Debug)]
struct DynamicFilters {
    inner: Vec<Option<Box<dyn Filter>>>,
}

impl DynamicFilters {
    pub fn new() -> Self {
        Self::default()
    }
}

fn add_filter(filter: impl Filter) -> FilterHandle {
    let filters: &mut DynamicFilters = &mut DYNAMIC_FILTERS
        .write()
        .expect("poisoned static in log config");
    let i = filters.inner.len();
    filters.inner.push(Some(Box::new(filter)));
    FilterHandle { i }
}

impl Filter for DynamicFilter {
    fn filter(&self, record: &Record) -> Response {
        DYNAMIC_FILTERS
            .read()
            .expect("poisoned static in log config")
            .filter(record)
    }
}

impl Filter for DynamicFilters {
    fn filter(&self, record: &Record) -> Response {
        for filter in &self.inner {
            if let Some(filter) = filter {
                let response = filter.filter(record);
                if response != Response::Neutral {
                    return response;
                }
            }
        }
        Response::Neutral
    }
}

impl Drop for FilterHandle {
    fn drop(&mut self) {
        let filters: &mut DynamicFilters = &mut DYNAMIC_FILTERS
            .write()
            .expect("poisoned static in log config");
        filters.inner[self.i] = None;
    }
}

#[derive(Debug)]
struct TargetFilter {
    level: Level,
    target: &'static str,
}

impl Filter for TargetFilter {
    fn filter(&self, record: &Record) -> Response {
        if record.level() < self.level {
            return Response::Neutral;
        }
        if record.target().starts_with(self.target) {
            Response::Reject
        } else {
            Response::Neutral
        }
    }
}
