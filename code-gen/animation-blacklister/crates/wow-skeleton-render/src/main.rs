use std::collections::HashMap;
use std::time::{Duration, Instant};

use animation_blacklister::resource::{ModelId, Resources};
use animation_blacklister::skeleton::{AnimatedBone, Animation, PosedBone, mean_skeleton_error};
use animation_blacklister::{SkeletonDefinition, log};
use anyhow::{Context, Result, anyhow, bail};
use kiss3d::glamx::Vec4Swizzles;
use kiss3d::prelude::*;
use log::*;
use serde::Deserialize;

const CONFIG_PATH: &str = "crates/wow-skeleton-render/config.ron";

#[derive(Deserialize, Debug)]
struct Config {
    render_bone_ids: bool,
    animation_master: AnimationDefinition,
    animation_comparisons: Box<[AnimationDefinition]>,
}

#[derive(Deserialize, Debug)]
struct AnimationDefinition {
    product: String,
    fdid: u32,
    animation: Option<(u16, u16)>,
    color: Color,
}

#[derive(Deserialize, Debug)]
enum Color {
    White,
    Red,
    Blue,
    Yellow,
    Cyan,
    Gray,
    Pink,
    Orange,
    Gold,
    Brown,
    Green,
    Teal,
}

#[kiss3d::main]
async fn main() {
    log::init(format!("log/wow-skeleton-render"));
    let _kiss3d_log_filters = [
        log::add_target_filter(log::Level::Debug, "wgpu"),
        log::add_target_filter(log::Level::Debug, "naga"),
    ];

    let config: Config = {
        let config_str = std::fs::read_to_string(CONFIG_PATH).expect("failed to read config");
        ron::from_str(&config_str).expect("failed to parse config")
    };
    info!("success: loaded config");
    debug!("config: {config:#?}");

    trace!("begin: loading resources");
    let animation_blacklister::Config { resource, .. } = animation_blacklister::Config::load();
    let res = Resources::load(resource).expect("failed to load resources");
    trace!("success: loading resources");

    let animation_master =
        load_animation(&res, config.animation_master).expect("failed to load animation");
    let animation_compares = config
        .animation_comparisons
        .into_iter()
        .map(|def| load_animation(&res, def))
        .into_iter()
        .collect::<Result<Box<_>>>()
        .expect("failed to load animation");
    info!("success: animation load");

    for (i, comparison) in animation_compares.iter().enumerate() {
        info!(
            r#"comparing skeleton {i} ({}) with master ({})"#,
            comparison.model_id, animation_master.model_id,
        );
        if comparison.duration != animation_master.duration {
            info!(
                " * durations were not the same ({} vs master {})",
                comparison.duration, animation_master.duration
            );
        } else {
            let animation_error =
                mean_skeleton_error(&animation_master.bones, &comparison.bones, |a, b| {
                    let error_sum: f32 = a
                        .positions
                        .iter()
                        .zip(b.positions.iter())
                        .map(|(a_pos, b_pos)| a_pos.distance_squared(*b_pos))
                        .sum();
                    error_sum / (a.positions.len() as f32)
                });
            info!(" * similarity error for animation was {}", animation_error);
        }
        let first_frame_error =
            mean_skeleton_error(&animation_master.bones, &comparison.bones, |a, b| {
                a.positions[0].distance_squared(b.positions[0])
            });
        info!(
            " * similarity error for first frame was {}",
            first_frame_error
        );
    }

    info!("begin: set up scene");
    let mut window = Window::new(module_path!()).await;
    window.rebind_close_key(Some(Key::Escape));
    let mut camera = OrbitCamera3d::new(Vec3::new(0.0, 1.0, 3.0), Vec3::new(0.0, 1.0, 0.0));
    let mut scene = SceneNode3d::empty();
    scene.add_light(Light::directional(Vec3::new(-0.6, 0.0, -0.6)));
    let mut state_master =
        AnimationState::new(&mut scene, animation_master, config.render_bone_ids);
    let mut state_compares = animation_compares
        .into_iter()
        .map(|animation| AnimationState::new(&mut scene, animation, config.render_bone_ids))
        .collect::<Box<_>>();
    info!("success: set up scene");

    info!("begin: render to window");
    let frame_period = Duration::from_secs_f32(1.0 / (Animation::FPS as f32));
    let mut duration = Duration::ZERO;
    let mut t = Instant::now();
    while window.render_3d(&mut scene, &mut camera).await {
        let t_new = Instant::now();
        duration += t_new.duration_since(t);
        t = Instant::now();
        let mut frames: usize = 0;
        while duration >= frame_period {
            frames += 1;
            duration -= frame_period;
        }
        if frames > 0 {
            state_master.update(frames);
            for state_compare in &mut state_compares {
                state_compare.update(frames);
            }
        }
        state_master.render(&mut window, &camera);
        for state_compare in &mut state_compares {
            state_compare.render(&mut window, &camera);
        }
    }
}

struct AnimationState<'a> {
    bones: Vec<(u32, SceneNode3d)>,
    bone_positions: HashMap<u32, Vec3>,
    skeleton_definition: RenderSkeleton<'a>,
    frame: usize,
    render_bone_ids: bool,
}

impl<'a> AnimationState<'a> {
    fn update(&mut self, frames: usize) {
        if self.skeleton_definition.duration < 2 {
            return;
        }
        self.frame = (self.frame + frames) % usize::from(self.skeleton_definition.duration);
        for (bone_id, bone) in self.bones.iter_mut() {
            let bone_pos = self.skeleton_definition.bones[bone_id].positions[self.frame];
            bone.set_position(bone_pos);
            self.bone_positions.insert(*bone_id, bone_pos);
        }
    }

    fn render(&mut self, window: &mut Window, camera: &impl Camera3d) {
        if self.render_bone_ids {
            let mut occupied_pos = Vec::new();
            for (id, &pos) in &self.bone_positions {
                let (window_w, window_h) = (window.width() as f32, window.height() as f32);
                let mut screen_pos = project(camera, window_w, window_h, pos);
                let mut color = WHITE;
                while occupied_pos.iter().any(|&pos| screen_pos == pos) {
                    screen_pos.y -= 13.0;
                    color = GOLD;
                }
                window.draw_text(&id.to_string(), screen_pos, 20.0, &Font::default(), color);
                occupied_pos.push(screen_pos);
            }
        }
        for (id, &pos) in &self.bone_positions {
            let parent = self.skeleton_definition.bones[id].parent_id;
            if parent.is_none() {
                continue;
            }
            let parent_pos = self.bone_positions.get(&parent.unwrap());
            if let Some(parent_pos) = parent_pos {
                window.draw_line(pos, *parent_pos, self.color(), 1.0, false);
            }
        }
    }

    fn new(scene: &mut SceneNode3d, skeleton: RenderSkeleton<'a>, render_bone_ids: bool) -> Self {
        let mut bones = Vec::new();
        let mut bone_positions: HashMap<u32, Vec3> = HashMap::new();
        for (bone_id, bone) in &skeleton.bones {
            let bone_pos = bone.positions[0];
            let bone = scene
                .add_sphere(0.01)
                .set_position(bone_pos)
                .set_color(bone_color(*bone_id));
            bones.push((*bone_id, bone));
            bone_positions.insert(*bone_id, bone_pos);
        }
        Self {
            bones,
            bone_positions,
            skeleton_definition: skeleton,
            frame: 0,
            render_bone_ids,
        }
    }

    fn color(&self) -> kiss3d::color::Color {
        self.skeleton_definition.color()
    }
}

// you would THINK `Camera3d::project` would work... BUT ALAS...
// (why in gods name is the fucking camera wrong about its own projection...)
fn project(camera: &impl Camera3d, window_w: f32, window_h: f32, pos: Vec3) -> Vec2 {
    let h_world_coord = pos.extend(1.0);
    let h_normalized_coord = camera.transformation() * h_world_coord;

    let normalized_coord = h_normalized_coord.xyz() / h_normalized_coord.w;

    Vec2::new(
        (1.0 + normalized_coord.x) * window_w / 2.0,
        (1.0 - normalized_coord.y) * window_h / 2.0,
    )
}

fn bone_color(id: u32) -> kiss3d::color::Color {
    match id {
        // GREEN LEFT ARM
        2 => LIME_GREEN,    // shoulder L
        0 => GREEN,         // arm L
        62 => PALE_GREEN,   // elbow L
        81 => FOREST_GREEN, // forearm L
        65 => FOREST_GREEN, // hand L

        // BLUE RIGHT ARM
        3 => SKY_BLUE,    // shoulder R
        1 => BLUE,        // arm R
        61 => STEEL_BLUE, // elbow R
        80 => ROYAL_BLUE, // forearm R
        64 => ROYAL_BLUE, // hand R

        // YELLOW-TO-ORANGE HEAD-TO-SPINE
        6 => YELLOW,          // head
        7 => GOLD,            // jaw
        54 => DARK_GOLDENROD, // spine low
        4 => ORANGE,          // spine low
        5 => ORANGE_RED,      // waist
        52 => ORANGE_RED,     // buckle

        26 => PURPLE, // root
        _ => RED,
    }
}

fn load_animation<'a>(res: &'a Resources, def: AnimationDefinition) -> Result<RenderSkeleton<'a>> {
    let product = match res.product_by_name(&def.product) {
        Some(some) => some,
        None => {
            bail!(
                r#"product "{}" did not exist in any configured installation"#,
                def.product
            );
        }
    };
    let model_id = res.model_id(def.fdid, product);
    match def.animation {
        Some(some) => info!(r#"loading animation {some:?} for {model_id}"#),
        None => info!(r#"loading bind pose for {model_id}"#),
    };
    let storage = res.open_local_storage(product)?;
    let render_skeleton = if let Some((animation_id, variation)) = def.animation {
        let animated_skeleton = SkeletonDefinition::parse(&storage, def.fdid, animation_id)
            .with_context(|| {
                format!(
                    "failed to parse skeleton data from model {} from {} in storage",
                    def.fdid, def.product
                )
            })?
            .evaluate_into_animated_skeleton()
            .with_context(|| {
                format!(
                    "failed to evaluate animated skeleton for model {} from {} in storage",
                    def.fdid, def.product
                )
            })?;
        trace!("raw loaded animated skeleton: {animated_skeleton:#?}");
        let mut animation: HashMap<u16, Animation> = animated_skeleton.animation;
        info!("{model_id}: variations for animation {animation_id}");
        dump_animation_variations(&animation);
        let variation = animation.remove(&variation).ok_or_else(|| {
            anyhow!(
                "specified animation variation did not exist: {} vs {:?}",
                variation,
                animation.keys().collect::<Vec<_>>()
            )
        })?;
        RenderSkeleton::from_animation(model_id, def, variation)
    } else {
        let skeleton_def = SkeletonDefinition::parse_for_idle(&storage, def.fdid)
            .context("failed to parse skeleton from model in storage, to get bind pose")?;
        trace!("raw loaded skeleton definition: {skeleton_def:#?}");
        RenderSkeleton::from_pose(model_id, def, skeleton_def.bind_pose)
    };
    Ok(render_skeleton)
}

fn dump_animation_variations(animation: &HashMap<u16, Animation>) {
    if animation.is_empty() {
        info!(" * no variations...");
        return;
    }
    let mut variations_sorted = animation.into_iter().collect::<Vec<_>>();
    variations_sorted.sort_by_key(|&(&id, _)| id);
    for (&id, variation) in variations_sorted {
        let duration_sec = variation.duration_sec();
        let Animation {
            duration,
            frequency,
            replay_range,
            skeleton: _,
        } = variation;
        let percentage = frequency * 100.0;
        let replay_range_str = replay_range
            .map(|(min, max)| format!(" [{min},{max}]"))
            .unwrap_or("".to_owned());
        info!(
            " * {id}: {percentage:.1?}%{replay_range_str} (for {duration} frames aka \
            {duration_sec:.2?}s)"
        );
    }
}

struct RenderSkeleton<'a> {
    pub model_id: ModelId<'a>,
    pub duration: usize,
    pub bones: HashMap<u32, RenderBone>,
    pub color: kiss3d::color::Color,
}

struct RenderBone {
    pub parent_id: Option<u32>,
    pub positions: Box<[Vec3]>,
}

impl<'a> RenderSkeleton<'a> {
    fn color(&self) -> kiss3d::color::Color {
        self.color
    }

    fn from_animation(
        model_id: ModelId<'a>,
        definition: AnimationDefinition,
        animation: Animation,
    ) -> Self {
        let bones = animation
            .skeleton
            .into_iter()
            .map(|(k, bone)| (k, RenderBone::from_animation_bone(bone)))
            .collect();
        Self {
            model_id,
            duration: animation.duration.into(),
            bones,
            color: (&definition.color).into(),
        }
    }

    fn from_pose(
        model_id: ModelId<'a>,
        definition: AnimationDefinition,
        pose: HashMap<u32, PosedBone>,
    ) -> Self {
        let bones = pose
            .into_iter()
            .map(|(k, bone)| (k, RenderBone::from_posed_bone(bone)))
            .collect();
        Self {
            model_id,
            duration: 1,
            color: (&definition.color).into(),
            bones,
        }
    }
}

impl RenderBone {
    fn from_animation_bone(bone: AnimatedBone) -> Self {
        Self {
            parent_id: bone.parent_id,
            positions: bone.positions.into_iter().map(adapt_vec).collect(),
        }
    }

    fn from_posed_bone(bone: PosedBone) -> Self {
        Self {
            parent_id: bone.parent_id,
            positions: Box::new([adapt_vec(bone.position)]),
        }
    }
}

// TODO confirm this? it contradicts the lighting reference in frame config, so maybe that needs to die too
fn adapt_vec(value: animation_blacklister::glam::Vec3) -> kiss3d::prelude::Vec3 {
    Vec3::new(value.y, value.z, value.x)
}

impl From<&Color> for kiss3d::color::Color {
    fn from(value: &Color) -> Self {
        match value {
            Color::White => kiss3d::color::WHITE,
            Color::Red => kiss3d::color::RED,
            Color::Blue => kiss3d::color::BLUE,
            Color::Yellow => kiss3d::color::YELLOW,
            Color::Cyan => kiss3d::color::CYAN,
            Color::Gray => kiss3d::color::GRAY,
            Color::Pink => kiss3d::color::PINK,
            Color::Orange => kiss3d::color::ORANGE,
            Color::Gold => kiss3d::color::GOLD,
            Color::Brown => kiss3d::color::BROWN,
            Color::Green => kiss3d::color::GREEN,
            Color::Teal => kiss3d::color::TEAL,
        }
    }
}
