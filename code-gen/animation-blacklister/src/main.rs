use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::{Write, stderr};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use animation_blacklister::animation_playlist::{AnimationPlaylist, AnimationPlaylists};
use animation_blacklister::blacklister::{AnimationBlacklister, BlacklistedAnimation};
use animation_blacklister::lua_gen::AnimationPlaylistData;
use animation_blacklister::resource::{ModelId, Product, Resources};
use animation_blacklister::timer::Timer;
use animation_blacklister::{log, *};
use anyhow::{Context, Result};
use log::*;

// TODO 1784020 vs 2022260 (was this a pabc note?)

fn main() -> Result<()> {
    log::init("log");
    let mut t = Timer::start_new();

    let config = Config::load();
    info!("success: loaded config");
    debug!("config: {config:#?}");

    let res = Resources::load(config.resource)?;
    info!("resources loaded: {:#?}", res);

    let whitelist: HashMap<u32, HashSet<&str>> = config
        .whitelist
        .iter()
        .map(|(&fdid, products)| (fdid, products.iter().map(String::as_str).collect()))
        .collect();

    // will parse 100 k:s of models: shut up parse trace spam
    let _log_filters = [
        log::add_target_filter(log::Level::Info, "wow_model_data"),
        log::add_target_filter(log::Level::Info, "wow_parse"),
    ];
    let blacklister = AnimationBlacklister::init(&res, &config.blacklist)?;
    blacklister.dump_config();

    trace!("evaluating number of models per available product from ModelFileData");
    let models_to_process: Vec<(&Product, BTreeSet<u32>)> = res
        .all_products()
        .iter()
        .map(|product| {
            let models = res.load_model_file_ids(product);
            models.map(|m| (product, m))
        })
        .collect::<Result<Vec<_>, _>>()?;
    info!("models to process per product:");
    for (product, models) in &models_to_process {
        info!(" * {product}: {}", models.len());
    }
    let total_model_count: HashMap<&Product, usize> = models_to_process
        .iter()
        .map(|(product, models)| (*product, models.len()))
        .collect();

    let mut progress = ProcessFileProgress::new(total_model_count, Timer::new());
    let pool = scoped_thread_pool::Pool::new(20);
    pool.scoped(|scope| {
        let res_sync = &res;
        let blacklister_sync = &blacklister;
        let (sender, receiver) = mpsc::channel();
        for (product, models) in models_to_process {
            let storage = res_sync
                .open_local_storage(product)
                .with_context(|| format!(r#"failed to open local storage for "{product}""#))
                .expect("failed to open storage");
            info!(
                r#"begin: processing all {} models in product "{product}""#,
                models.len()
            );
            for fdid in models {
                let model_id = res.model_id(fdid, product);
                progress.timer().start();
                trace!("begin: processing model {model_id}");
                let t_parse = progress.timer().start_sub("PARSE");
                if let Some(whitelist) = whitelist.get(&fdid)
                    && (whitelist.is_empty() || whitelist.contains(&*product.game_type))
                {
                    trace!("skipping {model_id} due to whitelist");
                    progress.register_result(model_id, Ok(None));
                    progress.timer.stop();
                    continue;
                }
                let parse_result = SkeletonDefinition::parse_for_idle(&storage, fdid)
                    .map_err(|e| outcome_from_parse_error(e, fdid));
                t_parse.stop();
                let skeleton_def = match parse_result {
                    Ok(ok) => ok,
                    Err(outcome) => {
                        progress.register_result(model_id, Err(outcome));
                        progress.timer.stop();
                        continue;
                    }
                };
                if skeleton_def.portrait_camera.is_none() {
                    trace!(
                        "skipping {model_id} because it was not a character model: had no portrait \
                        camera"
                    );
                    progress.register_result(
                        model_id,
                        Err(ProcessFileErrorOutcome::NotACharacterModel),
                    );
                    progress.timer.stop();
                    continue;
                }
                trace!("parse success: {model_id}");
                let t_fork = progress.timer().start_sub(" FORK");
                let sender_move = sender.clone();
                scope.execute(move || {
                    let result = blacklister_sync
                        .process_skeleton(model_id, skeleton_def)
                        .map_err(ProcessFileErrorOutcome::from);
                    if result.is_ok() {
                        trace!("skeleton process success: {model_id}");
                    }
                    sender_move
                        .send((model_id, result))
                        .expect("receiver hung up prematurely");
                });
                t_fork.stop();
                progress.timer().start_sub(" POLL");
                while let Ok((model, outcome)) = receiver.try_recv() {
                    progress.register_result(model, outcome);
                }
                progress.timer().stop_sub(" POLL");
                progress.timer().stop();
                progress.poll();
            }
        }
        info!("begin: joining threads");
        let mut t_join = Timer::start_new();
        drop(sender);
        for (model, outcome) in receiver {
            progress.register_result(model, outcome);
        }
        info!("success: joining threads took {:.0?}", t_join.stop());
    });
    let (blacklisted_animations, processed_models_per_product) = progress.finish();
    let mut playlists = blacklister.into_animation_playlists()?;
    for result in blacklisted_animations {
        playlists.add_from_blacklist(
            result.model,
            result.skeleton,
            &result.variation_blacklist,
            &result.references,
        )?;
    }
    let (data_per_model, report_per_model): (
        BTreeMap<u32, HashMap<Option<AnimationPlaylistData>, BTreeSet<&Product>>>,
        BTreeMap<u32, HashMap<Option<AnimationPlaylist<'_>>, BTreeSet<&Product>>>,
    ) = group_unique_playlists(processed_models_per_product, playlists);
    debug!("data_per_model = {data_per_model:#?}");

    info!("");
    info!("FINAL ANIMATION BLACKLIST REPORT:");
    for (fdid, products_per_playlist) in report_per_model {
        info!(" * {} ({fdid})", res.fdid_human_name(fdid));
        for (playlist, products) in products_per_playlist {
            if let Some(playlist) = playlist {
                let references_str: String = if playlist.references.is_empty() {
                    "direct blacklist".into()
                } else {
                    playlist
                        .references
                        .iter()
                        .map(ModelId::to_string)
                        .collect::<Box<[String]>>()
                        .join(", ")
                };
                info!("   - {products:?}: {playlist:?}");
                info!("       via {references_str}");
            } else {
                info!("   - {products:?}: <no blacklist>");
            }
        }
    }

    info!("");
    info!("finally: generating lua scripts to add-on");
    lua_gen::generate_animation_blacklist_scripts(config.lua_gen, &res, data_per_model)?;

    let main_duration = t.stop();
    info!(
        "program done: total execution time: {}",
        timer::fmt_long_duration(main_duration)
    );
    Ok(())
}

fn group_unique_playlists<'a>(
    processed_models_per_product: BTreeMap<&'a Product, BTreeSet<u32>>,
    playlists: AnimationPlaylists<'a>,
) -> (
    BTreeMap<u32, HashMap<Option<AnimationPlaylistData>, BTreeSet<&'a Product>>>,
    BTreeMap<u32, HashMap<Option<AnimationPlaylist<'a>>, BTreeSet<&'a Product>>>,
) {
    let mut data_per_model: BTreeMap<
        u32,
        HashMap<Option<AnimationPlaylistData>, BTreeSet<&Product>>,
    > = BTreeMap::new();
    let mut report_per_model: BTreeMap<
        u32,
        HashMap<Option<AnimationPlaylist>, BTreeSet<&Product>>,
    > = BTreeMap::new();
    for (model_id, playlist) in playlists {
        // no reason to generate a playlist that simply simulates the default animation behavior.
        // the only reason they are retained all the way here is for the report, to clarify which
        // models have been effectively whitelisted and why
        if !playlist.blacklist.is_empty() {
            data_per_model
                .entry(model_id.fdid)
                .or_default()
                .entry(Some(AnimationPlaylistData::from(&playlist)))
                .or_default()
                .insert(model_id.product);
        }
        report_per_model
            .entry(model_id.fdid)
            .or_default()
            .entry(Some(playlist))
            .or_default()
            .insert(model_id.product);
    }
    for (&fdid, products_per_playlist) in &mut data_per_model {
        let mut products_with_playlist: HashSet<&Product> = HashSet::new();
        for (_, products) in products_per_playlist.iter() {
            products_with_playlist.extend(products.iter());
        }
        let all_products_for_model: HashSet<&Product> = processed_models_per_product
            .iter()
            .filter_map(|(&product, models)| {
                if models.contains(&fdid) {
                    Some(product)
                } else {
                    None
                }
            })
            .collect();
        let products_without_playlist: BTreeSet<&Product> = all_products_for_model
            .difference(&products_with_playlist)
            .copied()
            .collect();
        for product_without_playlist in products_without_playlist {
            report_per_model
                .entry(fdid)
                .or_default()
                .entry(None)
                .or_default()
                .insert(product_without_playlist);
            products_per_playlist
                .entry(None)
                .or_default()
                .insert(product_without_playlist);
        }
    }
    (data_per_model, report_per_model)
}

struct ProcessFileProgress<'a> {
    total_count: usize,
    total_count_per_product: HashMap<&'a Product, usize>,
    processed_count: usize,
    processed_per_product: BTreeMap<&'a Product, BTreeSet<u32>>,
    error_count: BTreeMap<&'a Product, HashMap<ProcessFileErrorOutcome, usize>>,
    results: Vec<BlacklistedAnimation<'a>>,
    prev_report_time: Instant,
    timer: Timer,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum ProcessFileErrorOutcome {
    NotACharacterModel,
    InvalidData,
    NotFound,
    IoError,
    Encrypted,
    Corruption,
    M3NotSupported,
}

impl<'a> ProcessFileProgress<'a> {
    pub fn new(total_count_per_product: HashMap<&'a Product, usize>, timer: Timer) -> Self {
        let total_count: usize = total_count_per_product.iter().map(|(_, count)| count).sum();
        info!("begin: processing all {total_count} models");
        Self {
            total_count,
            total_count_per_product,
            processed_count: 0,
            processed_per_product: BTreeMap::default(),
            error_count: BTreeMap::default(),
            results: Vec::default(),
            prev_report_time: Instant::now(),
            timer,
        }
    }

    pub fn timer(&mut self) -> &mut Timer {
        &mut self.timer
    }

    pub fn register_result(
        &mut self,
        model: ModelId<'a>,
        outcome: Result<Option<BlacklistedAnimation<'a>>, ProcessFileErrorOutcome>,
    ) {
        match outcome {
            Ok(Some(ok)) => self.results.push(ok),
            Ok(None) => { /* pass */ }
            Err(err) => {
                *self
                    .error_count
                    .entry(model.product)
                    .or_default()
                    .entry(err)
                    .or_default() += 1
            }
        }
        self.processed_count += 1;
        self.processed_per_product
            .entry(model.product)
            .or_default()
            .insert(model.fdid);
        self.poll();
    }

    pub fn poll(&mut self) {
        const UPDATE_PERIOD: Duration = Duration::from_secs(10);
        let t = Instant::now();
        if t.duration_since(self.prev_report_time) >= UPDATE_PERIOD {
            let progress = 100 * self.processed_count / self.total_count;
            let mut stderr = stderr().lock();
            writeln!(stderr, "").expect("failed to write to stderr");
            writeln!(
                stderr,
                "# PROGRESS: processed {} / {} models ({progress}%)",
                self.processed_count, self.total_count,
            )
            .expect("failed to write to stderr");
            for line in self.build_report() {
                writeln!(stderr, "{line}").expect("failed to write to stderr");
            }
            self.prev_report_time = t;
            writeln!(stderr, "## TIMER REPORT").expect("failed to write to stderr");
            self.timer.report_to(stderr);
        }
    }

    pub fn finish(
        self,
    ) -> (
        Vec<BlacklistedAnimation<'a>>,
        BTreeMap<&'a Product, BTreeSet<u32>>,
    ) {
        info!("");
        info!("# JOB'S DONE: processed {} models", self.processed_count);
        for line in self.build_report() {
            info!("{line}");
        }
        info!("## TIMER REPORT");
        self.timer.report_to_log();
        (self.results, self.processed_per_product)
    }

    fn build_report(&self) -> Vec<String> {
        let mut lines = Vec::new();
        for (&product, processed_for_product) in &self.processed_per_product {
            let count = processed_for_product.len();
            let total = self.total_count_per_product[&product];
            let progress = 100 * count / total;
            lines.push(format!("* {product}: {count} / {total} ({progress}%)",));
        }
        lines.push(format!("## errors"));
        if self.error_count.is_empty() {
            lines.push(format!(" * no errors"));
        } else {
            for (&product, errors) in &self.error_count {
                let product_total = self.total_count_per_product[&product];
                for (&error, &count) in errors {
                    lines.push(format!(
                        "* {product}: {error:?}: {count} ({:.1}% / {:.1}%)",
                        100 * count / product_total,
                        100 * count / self.total_count
                    ));
                }
            }
        }
        lines
    }
}

impl From<anyhow::Error> for ProcessFileErrorOutcome {
    fn from(value: anyhow::Error) -> Self {
        error!("UNEXPECTED ERROR: {value}");
        ProcessFileErrorOutcome::InvalidData
    }
}

fn outcome_from_parse_error(err: ParseErrorOrBadCascFile, fdid: u32) -> ProcessFileErrorOutcome {
    match err {
        ParseErrorOrBadCascFile::ParseError(inner) => {
            error!("UNEXPECTED PARSE ERROR: failed to parse {fdid}: {inner}");
            ProcessFileErrorOutcome::InvalidData
        }
        ParseErrorOrBadCascFile::CascFileOpenError(inner) => match inner.kind() {
            // do not actually expect this ever to happen: the encryption check does not appear ever
            // to happen before an actual read
            casc_lib::CascLibErrorKind::EncryptedFile => {
                warn!("failed to decrypt while opening file {fdid}: {inner}");
                ProcessFileErrorOutcome::Encrypted
            }
            casc_lib::CascLibErrorKind::FileNotFound => {
                // not an actual `warn!` because this is expected to happen A LOT: i believe the
                // ModelFileData tables are simply very fallible wrt containing dead entries.
                // eg, for forever, almost half the models are missing, but this actually makes
                // sense, because the ModelFileData table for forever is roughly as big as that for
                // retail, but obviously forever is MUCH smaller than retail actually
                debug!("warning: file was not in storage: {fdid}: {inner}");
                ProcessFileErrorOutcome::NotFound
            }
            casc_lib::CascLibErrorKind::Uncategorized
            | casc_lib::CascLibErrorKind::NotSupported => {
                error!("UNEXPECTED STORAGE ERROR: failed to open {fdid}: {inner}");
                ProcessFileErrorOutcome::InvalidData
            }
        },
        ParseErrorOrBadCascFile::CascFileTestError(inner) => {
            outcome_from_file_test_error(inner, fdid)
        }
    }
}

fn outcome_from_file_test_error(err: CascFileTestError, fdid: u32) -> ProcessFileErrorOutcome {
    match err {
        CascFileTestError::EmptyFile => {
            error!("empty file {fdid}: {err}");
            ProcessFileErrorOutcome::IoError
        }
        CascFileTestError::EncryptedFile(e) => {
            warn!("failed to decrypt {fdid}: {e}");
            ProcessFileErrorOutcome::Encrypted
        }
        CascFileTestError::DataCorruption(e) => {
            warn!("some sort of data corruption during io while reading file {fdid} (error: {e})");
            ProcessFileErrorOutcome::Corruption
        }
        CascFileTestError::FileNotFound(e) => {
            warn!(
                "found file {fdid} in casc storage, but it did not actually exist: indexes are \
                    corrupt, or something (error: {e})"
            );
            ProcessFileErrorOutcome::Corruption
        }
        CascFileTestError::InvalidFileSignature { file_signature } => match file_signature.as_str()
        {
            "M3DT" => {
                warn!("skipping m3 (hopefully this format is not common for characters): {fdid}");
                ProcessFileErrorOutcome::M3NotSupported
            }
            _ => {
                error!("unexpected file type {file_signature:?}: {fdid}");
                ProcessFileErrorOutcome::IoError
            }
        },
        CascFileTestError::Unknown(err) => {
            error!("UNEXPECTED PARSE ERROR: failed to parse {fdid}: {err}");
            ProcessFileErrorOutcome::InvalidData
        }
    }
}
