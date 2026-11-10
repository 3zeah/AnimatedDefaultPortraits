use std::collections::{HashMap, HashSet};
use std::fmt;

use anyhow::{Context, Result, bail};
use log::*;

use crate::animation_playlist::AnimationPlaylists;
use crate::resource::{ModelId, Product, Resources};
use crate::skeleton::Animation;
use crate::timer::Timer;
use crate::{AnimatedSkeleton, ModelConfig, SkeletonDefinition, skeleton};

#[derive(Debug)]
pub struct AnimationBlacklister<'a> {
    references: Vec<AnimationBlacklistReference<'a>>,
}

pub struct BlacklistedAnimation<'a> {
    pub model: ModelId<'a>,
    pub skeleton: AnimatedSkeleton,
    pub config: ModelConfig,
    pub references: HashSet<ModelId<'a>>,
}

struct AnimationBlacklistReference<'a> {
    pub reference: (ModelId<'a>, AnimatedSkeleton),
    pub members: Vec<(ModelId<'a>, AnimatedSkeleton)>,
    pub config: ModelConfig,
}

impl<'a> AnimationBlacklister<'a> {
    // undead f to human f is ~0.005 error, undead f to belf f is ~0.006 error
    // female skeletons especially are similar, but they do not actually share skeletal animations
    const POSE_ERROR_MARGIN: f32 = 0.001;
    const INFO_POSE_ERROR_MARGIN: f32 = Self::POSE_ERROR_MARGIN * 10.0;

    // it is probably a good idea to keep this higher than the pose margin: animations are only
    // compared after the skeletons are identified as the same, via the stricter pose-error margin
    // applied to the bind poses. and animations that need to be blacklisted tend to be distinct
    // within the animation set of a single skeleton
    //
    // * undead m variation 0 to variation 1 is ~0.089 error (not same)
    // * undead m variation 1 to crack elf m variation 1 is ~0.005 error (same)
    const ANIMATION_ERROR_MARGIN: f32 = 0.01;
    const INFO_ANIMATION_ERROR_MARGIN: f32 = Self::ANIMATION_ERROR_MARGIN * 10.0;

    pub fn dump_config(&self) {
        info!("BLACKLIST CONFIG AFTER GROUPING:");
        for reference in &self.references {
            info!(" * {}: {:?}", reference.model_id(), reference.config);
            for &(member_id, _) in &reference.members {
                info!("   - {member_id}");
            }
        }
    }

    pub fn into_animation_playlists(self) -> Result<AnimationPlaylists<'a>> {
        let mut playlists = AnimationPlaylists::new();
        for reference in self.references {
            let config = reference.config;
            let (reference_model, reference_skeleton) = reference.reference;
            playlists.add_from_blacklist(
                reference_model,
                reference_skeleton,
                &config,
                &HashSet::default(),
            )?;
            for (model, skeleton) in reference.members {
                let reference_set: HashSet<ModelId> = [reference_model].into_iter().collect();
                playlists.add_from_blacklist(model, skeleton, &config, &reference_set)?;
            }
        }
        Ok(playlists)
    }

    pub fn process_skeleton(
        &self,
        model_id: ModelId<'a>,
        skeleton_def: SkeletonDefinition,
    ) -> Result<Option<BlacklistedAnimation<'a>>> {
        let has_extra_variation = skeleton_def
            .animation_definition
            .keys()
            .any(|&variation_id| variation_id != 0);
        if !has_extra_variation {
            trace!("skip processing {model_id} as it had no extra animation variations");
            return Ok(None);
        }
        for reference in &self.references {
            if model_id.fdid == reference.fdid() && model_id.product == reference.product() {
                trace!("skip processing {model_id} as it was already a reference skeleton");
                return Ok(None);
            }
            for &(reference_member_id, _) in &reference.members {
                if model_id == reference_member_id {
                    trace!("skip processing {model_id} as it was already a reference skeleton");
                    return Ok(None);
                }
            }
        }
        let bind_pose = &skeleton_def.bind_pose;
        let mut skeleton_matches = Vec::new();
        let mut skeleton_similarity_reports = Vec::new();
        for (i, reference) in self.references.iter().enumerate() {
            let bind_pose_error = skeleton::mean_error(bind_pose, &reference.skeleton().bind_pose);
            if bind_pose_error >= Self::POSE_ERROR_MARGIN {
                if bind_pose_error < Self::INFO_POSE_ERROR_MARGIN {
                    skeleton_similarity_reports.push(format!(
                        "BEWARE: skeletons were not the same, but {} was similar to {} (bind-pose \
                        error of {} vs error margin {})",
                        model_id,
                        reference.model_id(),
                        bind_pose_error,
                        Self::POSE_ERROR_MARGIN,
                    ));
                }
                continue;
            }
            skeleton_matches.push((i, bind_pose_error));
        }
        if skeleton_matches.is_empty() {
            for line in skeleton_similarity_reports {
                info!("{line}");
            }
            return Ok(None);
        }
        let mut config: Option<ModelConfig> = None;
        let mut references: HashSet<ModelId> = HashSet::new();
        // this evaluation is expensive, which is why it is delayed as long as possible
        let animated_skeleton = skeleton_def.evaluate_into_animated_skeleton()?;
        let mut animation_similarity_report = Vec::new();
        let mut report_has_beware_info = false;
        // check each blacklisted model that had the same skeleton as this whether a blacklisted
        // animation is shared between them
        for (reference_index, bind_pose_error) in skeleton_matches {
            let reference = &self.references[reference_index];
            let mut sub_report = Vec::new();
            let reference_animation = &reference.skeleton().animation;
            match &reference.config {
                // if a model is set to play some animation, it is because all idle variations were
                // bad: any other model that has the same set of idle variations should inherit this
                // config
                ModelConfig::PlayAnimation(animation_id) => {
                    let reference_variations = reference_animation.keys().collect::<HashSet<_>>();
                    let animation_variations =
                        animated_skeleton.animation.keys().collect::<HashSet<_>>();
                    if reference_variations != animation_variations {
                        continue;
                    }
                    let mut all_variations_same = true;
                    let mut all_variations_similar = true;
                    for &variation_id in &animation_variations {
                        let reference_variation = &reference_animation[variation_id];
                        let variation = &animated_skeleton.animation[variation_id];
                        if reference_variation.duration != variation.duration {
                            all_variations_same = false;
                            all_variations_similar = false;
                            break;
                        }
                        let variation_error = Animation::mean_error(reference_variation, variation);
                        if variation_error < Self::ANIMATION_ERROR_MARGIN {
                            continue;
                        }
                        all_variations_same = false;
                        if variation_error < Self::INFO_ANIMATION_ERROR_MARGIN {
                            sub_report.push(format!(
                                "   > BEWARE: the reference was configured to play animation \
                                {animation_id}, but will not inherit that, because variations
                                {variation_id} are only similar (but not the same): similarity \
                                error of {variation_error}",
                            ));
                        } else {
                            all_variations_similar = false;
                            break;
                        }
                    }
                    if all_variations_similar {
                        report_has_beware_info = true;
                    }
                    if all_variations_same {
                        debug!(
                            "{model_id} was the same as reference {} set to play animation \
                            {animation_id}: inheriting that",
                            reference.model_id()
                        );
                        references.clear();
                        references.insert(reference.model_id());
                        config = Some(reference.config.clone());
                        break;
                    }
                }
                // otherwise, if there is a set of blacklisted variations, check each to see whether
                // this model shares one of those blacklisted variations, and propagate the
                // blacklist to that variation if so
                ModelConfig::BlacklistIdle(reference_blacklist) => {
                    for (&variation_id, variation) in &animated_skeleton.animation {
                        if variation_id == 0 {
                            continue;
                        }
                        for reference_variation_id in reference_blacklist {
                            let reference_variation = &reference_animation[reference_variation_id];
                            let variation_error =
                                Animation::mean_error(variation, reference_variation);
                            if variation_error < Self::ANIMATION_ERROR_MARGIN {
                                sub_report.push(format!(
                                    "   > new blacklist: variation {} = blacklisted reference {} \
                                    (similarity error of {})",
                                    variation_id, reference_variation_id, variation_error,
                                ));
                                // had a match: add this variation to the blacklist
                                references.insert(reference.model_id());
                                match &mut config {
                                    Some(config) => match config {
                                        ModelConfig::BlacklistIdle(blacklist) => {
                                            blacklist.insert(variation_id);
                                        }
                                        // this should never happen, because when a `PlayAnimation`
                                        // config is set, the loop is broken
                                        ModelConfig::PlayAnimation(_) => bail!(
                                            "illegal state: while processing {model_id} vs \
                                            reference {}: already had config {config:?}, and \
                                            attempted to add idle-variation blacklist for \
                                            {variation_id}",
                                            reference.model_id()
                                        ),
                                    },
                                    None => {
                                        config = Some(ModelConfig::BlacklistIdle(
                                            [variation_id].into_iter().collect(),
                                        ))
                                    }
                                };
                            } else if variation_error < Self::INFO_ANIMATION_ERROR_MARGIN {
                                report_has_beware_info = true;
                                sub_report.push(format!(
                                    "   > BEWARE: will not blacklist variation {}, but it is \
                                    similar to blacklisted reference {} (similarity error of {})",
                                    variation_id, reference_variation_id, variation_error,
                                ));
                            }
                        }
                    }
                }
            }
            if !sub_report.is_empty() {
                animation_similarity_report.push(format!(
                    " * {} had same skeleton as {} (bind-pose error of {})",
                    model_id,
                    reference.model_id(),
                    bind_pose_error,
                ));
                animation_similarity_report.extend(sub_report.into_iter());
            }
        }
        if let Some(config) = config {
            if let ModelConfig::BlacklistIdle(variation_blacklist) = &config
                && variation_blacklist.contains(&0)
            {
                bail!("not supported: attempted to blacklist variation 0 (for {model_id})");
            }
            let blacklisted_animation = BlacklistedAnimation {
                model: model_id,
                skeleton: animated_skeleton,
                config,
                references,
            };
            Ok(Some(blacklisted_animation))
        } else {
            if report_has_beware_info {
                animation_similarity_report.insert(
                    0,
                    format!(
                        "BEWARE: {model_id} was not blacklisted, but was similar to at least one \
                        blacklisted animation"
                    ),
                );
                info!("{}", animation_similarity_report.join("\n"));
            } else {
                animation_similarity_report.insert(
                    0,
                    format!("{model_id} had animations matching those in the blacklist"),
                );
                debug!("{}", animation_similarity_report.join("\n"));
            }
            Ok(None)
        }
    }

    pub fn init(
        res: &'a Resources,
        blacklist_config: &HashMap<u32, HashMap<Box<[String]>, ModelConfig>>,
    ) -> Result<Self> {
        let mut blacklist: HashMap<&str, HashMap<u32, ModelConfig>> = HashMap::new();
        for (&fdid, blacklists_for_model) in blacklist_config {
            for (game_types, config) in blacklists_for_model {
                for game_type in game_types {
                    blacklist
                        .entry(game_type)
                        .or_default()
                        .insert(fdid, config.clone());
                }
            }
        }
        for (&game_type, per_model) in blacklist.iter() {
            for (fdid, config) in per_model.iter() {
                if let ModelConfig::BlacklistIdle(blacklisted_variations) = config
                    && blacklisted_variations.contains(&0)
                {
                    bail!(
                        "not supported: attempted to blacklist idle variation 0 (for {fdid} in \
                        \"{game_type}\")"
                    );
                }
            }
        }
        info!("configured animation blacklist:");
        for (&game_type, blacklist_per_model) in &blacklist {
            for (&fdid, blacklist) in blacklist_per_model {
                let file_name = res.fdid_human_name(fdid);
                info!(r#" * {file_name} ({fdid}) in "{game_type}": {blacklist:?}"#);
            }
        }
        info!("begin: processing reference skeletons");
        let mut t_config = Timer::start_new();
        let mut self_build = AnimationBlacklister::new();
        for (game_type, blacklist_per_model) in blacklist {
            let product = match res.product_by_game_type(game_type) {
                Some(some) => some,
                None => {
                    bail!(
                        r#"game type "{game_type}" did not exist in any configured installation"#
                    );
                }
            };
            let storage = res.open_local_storage(product)?;
            for (fdid, config) in blacklist_per_model {
                let model_id = res.model_id(fdid, product);
                let skeleton = SkeletonDefinition::parse_for_idle(&storage, fdid)
                    .with_context(|| format!("failed to parse skeleton for {model_id}"))?
                    .evaluate_into_animated_skeleton()
                    .with_context(|| {
                        format!("failed to evaluate animated skeleton for {model_id}")
                    })?;
                match &config {
                    ModelConfig::BlacklistIdle(variations) => {
                        for variation_id in variations {
                            if !skeleton.animation.contains_key(&variation_id) {
                                bail!(
                                    "bad config: for {model_id}, attempted to blacklist idle \
                                    variation {variation_id}, but only had {:?}",
                                    skeleton.animation.keys().collect::<Vec<_>>()
                                );
                            }
                        }
                    }
                    ModelConfig::PlayAnimation(id) => {
                        if !skeleton.animation_ids.contains(&id.into()) {
                            bail!(
                                "bad config: for {model_id}, attempted to play animation {id}, but \
                                only had {:?}",
                                skeleton.animation_ids
                            );
                        }
                    }
                }
                self_build.add_reference_skeleton(model_id, skeleton, config)?;
            }
        }
        let time_config = t_config.stop();
        drop(t_config);
        info!("success: processing reference skeletons took {time_config:.1?}");
        Ok(self_build)
    }

    fn add_reference_skeleton(
        &mut self,
        model_id: ModelId<'a>,
        skeleton: AnimatedSkeleton,
        config: ModelConfig,
    ) -> Result<()> {
        trace!("adding configured reference model: {model_id}");
        for group in &mut self.references {
            trace!(
                "ensuring new reference does not conflict with {}",
                group.model_id()
            );
            if Self::reference_skeletons_are_equivalent(
                model_id,
                &skeleton,
                group.model_id(),
                group.skeleton(),
            ) {
                if config != group.config {
                    bail!(
                        "conflicting blacklist config between equivalent skeletons: {} had config \
                        {:?}, but {} had {:?}",
                        model_id,
                        config,
                        group.model_id(),
                        group.config
                    );
                }
                debug!(
                    "configured reference model {model_id} was equivalent to {}: merging groups",
                    group.model_id()
                );
                group.members.push((model_id, skeleton));
                return Ok(());
            }
        }
        let group = AnimationBlacklistReference {
            reference: (model_id, skeleton),
            members: Default::default(),
            config,
        };
        self.references.push(group);
        Ok(())
    }

    fn reference_skeletons_are_equivalent(
        a_id: ModelId<'_>,
        a: &AnimatedSkeleton,
        b_id: ModelId<'_>,
        b: &AnimatedSkeleton,
    ) -> bool {
        let bind_pose_error = skeleton::mean_error(&a.bind_pose, &b.bind_pose);
        if bind_pose_error < Self::INFO_POSE_ERROR_MARGIN {
            debug!(
                "BEWARE: skeletons in configured blacklist are similar: bind pose similarity error \
                was {bind_pose_error}, vs the {} error margin (for {a_id} vs reference {b_id})",
                Self::POSE_ERROR_MARGIN
            );
        }
        if bind_pose_error >= Self::POSE_ERROR_MARGIN {
            trace!(
                "skeletons are not the same: bind pose similarity error was {bind_pose_error}, vs \
                the {} error margin (for {a_id} vs reference {b_id})",
                Self::POSE_ERROR_MARGIN
            );
            return false;
        }
        let a_animation_variations = a.animation.keys().collect::<HashSet<_>>();
        let b_animation_variations = b.animation.keys().collect::<HashSet<_>>();
        if a_animation_variations != b_animation_variations {
            trace!(
                "skeletons do not have the same animations: set of animation variations was not \
                the same: {:?} vs {:?} (for {a_id} vs reference {b_id})",
                a_animation_variations, b_animation_variations
            );
            return false;
        }
        for &variation_id in &a_animation_variations {
            let variation_a = &a.animation[variation_id];
            let variation_b = &b.animation[variation_id];
            if variation_a.duration != variation_b.duration {
                trace!(
                    "skeletons do not have the same animations: variation {} had differing \
                    durations: {} vs {} (for {a_id} vs reference {b_id})",
                    variation_id, variation_a.duration, variation_b.duration
                );
                return false;
            }
        }
        for variation_id in a_animation_variations {
            let variation_a = &a.animation[variation_id];
            let variation_b = &b.animation[variation_id];
            let animation_error = Animation::mean_error(variation_a, variation_b);
            trace!(
                "animation similarity for variation {} error was {}, vs the {} error margin (for \
                {a_id} vs reference {b_id})",
                variation_id,
                animation_error,
                Self::POSE_ERROR_MARGIN
            );
            if animation_error < Self::INFO_POSE_ERROR_MARGIN {
                debug!(
                    "BEWARE: animation variation {variation_id} for {a_id} was similar to {b_id} \
                    (similarity error of {animation_error})"
                );
            }
            // use stricter pose-error margin over the animation-error: although the latter is used
            // when evaluating similarity between processed models and the reference models, the
            // comparison here is for evaluating reference-model equivalence. strictness here
            // alleviates the triangle problem where, eg, model A is equivalent to B is similar to
            // C, but C is not similar to A. in this scenario, whether C inherits the A/B blacklist
            // depends on whether A or B is used as a reference. this problem is alleviated by being
            // more strict in evaluating equivalence (in the example, between A and B)
            if animation_error >= Self::POSE_ERROR_MARGIN {
                trace!(
                    "animation similarity for variation {variation_id} was not enough: \
                    {animation_error} vs the {} error margin (for {a_id} vs reference {b_id})",
                    Self::POSE_ERROR_MARGIN
                );
                return false;
            }
        }
        true
    }

    fn new() -> Self {
        Self {
            references: Vec::default(),
        }
    }
}

impl<'a> AnimationBlacklistReference<'a> {
    pub fn model_id(&self) -> ModelId<'a> {
        self.reference.0
    }

    pub fn fdid(&self) -> u32 {
        self.reference.0.fdid
    }

    pub fn product(&self) -> &'a Product {
        self.reference.0.product
    }

    pub fn skeleton(&self) -> &AnimatedSkeleton {
        &self.reference.1
    }
}

impl fmt::Debug for AnimationBlacklistReference<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("SkeletonEquivalenceGroup")
            .field("reference", &self.reference.0)
            .field("members", &self.members)
            .field("variation_blacklist", &self.config)
            .finish()
    }
}
