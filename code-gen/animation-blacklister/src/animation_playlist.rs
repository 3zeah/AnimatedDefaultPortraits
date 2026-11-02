use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet, btree_map};
use std::fmt;

use anyhow::{Context, Result, anyhow, bail};

use crate::AnimatedSkeleton;
use crate::resource::ModelId;
use crate::skeleton::Animation;

pub struct AnimationPlaylists<'a> {
    playlists: BTreeMap<ModelId<'a>, AnimationPlaylist<'a>>,
}

#[derive(Hash, PartialEq, Eq)]
pub struct AnimationPlaylist<'a> {
    pub variations: BTreeMap<u16, AnimationVariation>,
    // not necessary to define a playlist, but track this for debugging
    pub blacklist: BTreeSet<u16>,
    // also for debugging: the set of models that induced this playlist (blacklists are constructed
    // by similarity: a model that is similar to a blacklisted reference model inherits that
    // blacklist)
    pub references: BTreeSet<ModelId<'a>>,
}

#[derive(Clone, Copy, Hash, PartialEq, Eq)]
pub struct AnimationVariation {
    pub probability_per_mille: u16,
    pub replay_range: Option<(u32, u32)>,
}

impl<'a> AnimationPlaylists<'a> {
    pub fn iter(&self) -> impl Iterator<Item = (&ModelId<'a>, &AnimationPlaylist<'a>)> {
        self.playlists.iter()
    }

    pub fn add_from_blacklist(
        &mut self,
        model: ModelId<'a>,
        animation: AnimatedSkeleton,
        blacklist: &HashSet<u16>,
        references: &HashSet<ModelId<'a>>,
    ) -> Result<()> {
        let playlist = AnimationPlaylist::from_blacklisted_animation(
            animation.animation,
            blacklist,
            references,
        )
        .with_context(|| format!("failed to evaluate blacklisted animation for {model}"))?;
        let prev = self.playlists.insert(model, playlist);
        if prev.is_some() {
            bail!("multiple animation blacklists added for {model}");
        }
        Ok(())
    }

    pub fn new() -> Self {
        Self {
            playlists: Default::default(),
        }
    }
}

impl<'a> AnimationPlaylist<'a> {
    fn from_blacklisted_animation(
        animation: HashMap<u16, Animation>,
        blacklist: &HashSet<u16>,
        references: &HashSet<ModelId<'a>>,
    ) -> Result<Self> {
        let whitelist: Box<[(u16, Animation)]> = animation
            .into_iter()
            .filter(|(variant_id, _)| !blacklist.contains(variant_id))
            .collect();
        let remaining_probability_sum: f32 = whitelist
            .iter()
            .map(|(_, animation)| animation.frequency)
            .sum();
        let probability_adjustment = 1.0 / remaining_probability_sum;
        let mut remaining_probability_per_mille: u16 = 1000;
        let mut variations: BTreeMap<u16, AnimationVariation> = BTreeMap::new();
        for &(variant_id, ref animation) in &whitelist {
            if variant_id == 0 {
                continue;
            }
            let probability_per_mille =
                (1000.0 * animation.frequency * probability_adjustment).round() as u16;
            remaining_probability_per_mille -= probability_per_mille;
            let variation = AnimationVariation {
                probability_per_mille,
                replay_range: animation.replay_range,
            };
            variations.insert(variant_id, variation);
        }
        let base_variation = whitelist
            .get(0)
            .ok_or_else(|| anyhow!("illegal state: variation 0 was blacklisted"))?;
        variations.insert(
            0,
            AnimationVariation {
                probability_per_mille: remaining_probability_per_mille,
                replay_range: base_variation.1.replay_range,
            },
        );
        Ok(Self {
            variations,
            blacklist: blacklist.into_iter().copied().collect(),
            references: references.into_iter().copied().collect(),
        })
    }
}

impl<'a> IntoIterator for AnimationPlaylists<'a> {
    type Item = (ModelId<'a>, AnimationPlaylist<'a>);

    type IntoIter = btree_map::IntoIter<ModelId<'a>, AnimationPlaylist<'a>>;

    fn into_iter(self) -> Self::IntoIter {
        self.playlists.into_iter()
    }
}

impl<'a> IntoIterator for &'a AnimationPlaylists<'a> {
    type Item = (&'a ModelId<'a>, &'a AnimationPlaylist<'a>);

    type IntoIter = btree_map::Iter<'a, ModelId<'a>, AnimationPlaylist<'a>>;

    fn into_iter(self) -> Self::IntoIter {
        self.playlists.iter()
    }
}

impl fmt::Debug for AnimationPlaylist<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{{ blacklist: {:?} => playlist: {:?} }}",
            self.blacklist, self.variations
        )
    }
}

impl AnimationVariation {
    pub fn percentage(&self) -> f32 {
        f32::from(self.probability_per_mille) / 10.0
    }
}

impl fmt::Debug for AnimationVariation {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let percentage_fmt = format_args!("{:.1}%", self.percentage());
        if let Some((replay_min, replay_max)) = self.replay_range {
            write!(f, "{{{percentage_fmt}, [{replay_min},{replay_max}]}}")
        } else {
            write!(f, "{percentage_fmt}")
        }
    }
}
