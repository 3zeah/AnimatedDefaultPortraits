use std::collections::HashMap;
use std::io;
use std::time::{Duration, Instant};

use crate::log;

#[derive(Debug)]
pub struct Timer {
    t0: Option<Instant>,
    results: Vec<Duration>,
    sub: HashMap<&'static str, Timer>,
}

impl Timer {
    pub fn new() -> Self {
        Self {
            t0: None,
            results: Default::default(),
            sub: Default::default(),
        }
    }

    pub fn start_new() -> Self {
        Self {
            t0: Some(Instant::now()),
            results: Default::default(),
            sub: Default::default(),
        }
    }

    pub fn start(&mut self) {
        let t = Instant::now();
        self.t0 = Some(t);
    }

    pub fn stop(&mut self) -> Duration {
        for (_, sub) in &mut self.sub {
            if sub.is_started() {
                sub.stop();
            }
        }
        let t = Instant::now();
        let duration = t.duration_since(self.t0.expect("timer was not started"));
        self.t0 = None;
        self.results.push(duration);
        duration
    }

    pub fn start_sub(&mut self, name: &'static str) -> &mut Self {
        self.sub
            .entry(name)
            .and_modify(Self::start)
            .or_insert_with(Self::start_new)
    }

    pub fn stop_sub(&mut self, name: &'static str) {
        self.sub
            .get_mut(name)
            .expect("sub timer was not started")
            .stop();
    }

    pub fn avg(&self) -> Option<Duration> {
        if self.results.is_empty() {
            return None;
        }
        Some(self.total().div_f32(self.results.len() as f32))
    }

    pub fn total(&self) -> Duration {
        self.results.iter().sum::<Duration>()
    }

    pub fn report_to_log(&self) {
        for line in self.build_report() {
            log::info!("{line}");
        }
    }

    pub fn report_to(&self, mut dst: impl io::Write) {
        for line in self.build_report() {
            writeln!(dst, "{line}").expect("failed to write to stderr");
        }
    }

    fn is_started(&self) -> bool {
        self.t0.is_some()
    }

    fn build_report(&self) -> Vec<String> {
        let mut lines = Vec::new();
        self.build_report_recurse(&mut lines, 0, None, None);
        lines
    }

    fn build_report_recurse(
        &self,
        result: &mut Vec<String>,
        indents: usize,
        parent: Option<Duration>,
        name: Option<&str>,
    ) {
        let indent = "  ".repeat(indents);
        let bullet = if indents % 2 == 0 { "*" } else { "-" };
        let name_tag = if let Some(name) = name {
            format_args!("{}: ", name.to_string())
        } else {
            format_args!("")
        };
        let total = self.total();
        let avg = self.avg();
        let count = self.results.len();
        let util_tag = if let Some(parent) = parent
            && !parent.is_zero()
        {
            format_args!(
                ", util: {:.1}%",
                total.mul_f32(100f32).div_duration_f32(parent)
            )
        } else {
            format_args!("")
        };
        let avg_fmt = if let Some(avg) = &avg {
            format!("{avg:.1?}")
        } else {
            "<none>".to_string()
        };
        let time_tag = if count > 1 {
            format_args!("avg: {avg_fmt} ({} over {count})", fmt_long_duration(total))
        } else {
            format_args!("time: {avg_fmt:.1?}")
        };
        result.push(format!("{indent}{bullet} {name_tag}{time_tag}{util_tag}"));
        if !self.sub.is_empty() {
            result.push(format!("{indent}{bullet} sub timers:"));
            for (&name, sub) in &self.sub {
                sub.build_report_recurse(result, indents + 1, Some(total), Some(name));
            }
        }
    }
}

pub fn fmt_long_duration(duration: Duration) -> String {
    const MINUTE: Duration = Duration::from_secs(60);
    let minutes = duration.div_duration_f32(MINUTE).floor() as u32;
    if minutes > 0 {
        let seconds = duration - minutes * MINUTE;
        format!("{minutes}min {seconds:.0?}")
    } else {
        format!("{duration:.0?}")
    }
}

impl Drop for Timer {
    fn drop(&mut self) {
        if self.is_started() {
            self.stop();
        }
    }
}
