use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::fs;
use std::io::{BufRead, BufReader, BufWriter};
use std::path::Path;

use anyhow::{Context, Result, anyhow, bail};
use serde::Deserialize;

use crate::animation_playlist::{AnimationPlaylist, AnimationVariation};
use crate::log::*;
use crate::resource::{Product, Resources};

#[derive(Deserialize, Debug)]
pub struct Config {
    pub addon_path: Box<Path>,
    pub addon_name: Box<str>,
    pub generated_dir: Box<str>,
    pub generated_file_base_name: Box<str>,
    pub generated_table_name: Box<str>,
}

type AnimationPlaylists = BTreeMap<AnimationPlaylistData, BTreeSet<u32>>;

#[derive(Clone, Hash, PartialEq, Eq, PartialOrd, Ord, Default, Debug)]
pub struct AnimationPlaylistData(pub BTreeMap<u16, AnimationVariationData>);

#[derive(Clone, Copy, Hash, PartialEq, Eq, PartialOrd, Ord, Debug)]
pub struct AnimationVariationData {
    pub probability_per_mille: u16,
}

pub fn generate_animation_blacklist_scripts(
    config: Config,
    res: &Resources,
    playlists: BTreeMap<u32, HashMap<Option<AnimationPlaylistData>, BTreeSet<&Product>>>,
) -> Result<()> {
    // group playlists by game type (will generate separate script for each)
    let playlists_by_game_type: BTreeMap<Option<&str>, AnimationPlaylists> =
        group_playlists_by_game_type_filter(res, playlists);
    debug!("playlists_by_game_type = {playlists_by_game_type:#?}");

    // clean up generated code dir
    let addon_path = &config.addon_path;
    if !addon_path.is_dir() {
        bail!("expected add-on path, {addon_path:?}, did not exist or was not a directory");
    }
    let generated_code_dir = addon_path.join(&*config.generated_dir);
    if generated_code_dir.exists() {
        if !generated_code_dir.is_dir() {
            bail!(
                "directory reserved for generated code, {generated_code_dir:?}, was not a directory"
            );
        }
        fs::remove_dir_all(&generated_code_dir)
            .context("failed to clear add-on subdirectory for generated code")?;
    }
    fs::create_dir(&generated_code_dir)
        .context("failed to create add-on subdirectory for generated code")?;

    // generate code
    let generated_code_file_base_name = &config.generated_file_base_name;
    let mut generated_files: Vec<(Box<Path>, Option<&str>)> = Vec::new();
    let empty_playlists: AnimationPlaylists = AnimationPlaylists::default();
    let main_playlists: &AnimationPlaylists = playlists_by_game_type
        .get(&None)
        .unwrap_or(&empty_playlists);
    {
        let file_path = generated_code_dir.join(format!("{generated_code_file_base_name}.lua"));
        let main_file = fs::File::create_new(&file_path)
            .with_context(|| format!("failed to open new generated code file: {file_path:?}"))?;
        generate_init_playlists_lua(res, main_file, &config.generated_table_name, main_playlists)
            .with_context(|| format!("failed to generate code to {file_path:?}"))?;
        let path_in_addon = relativize_path(file_path, addon_path)
            .context("failed to relativize path of generated file within add-on directory")?;
        info!(" * generated {path_in_addon:?}");
        generated_files.push((path_in_addon, None));
    }
    for (game_type, playlists) in playlists_by_game_type {
        if let Some(game_type) = game_type {
            let file_path =
                generated_code_dir.join(format!("{generated_code_file_base_name}_{game_type}.lua"));
            let file = fs::File::create_new(&file_path).with_context(|| {
                format!("failed to open new generated code file: {file_path:?}")
            })?;
            generate_append_playlists_lua(res, file, &config.generated_table_name, &playlists)
                .with_context(|| format!("failed to generate code to {file_path:?}"))?;
            let path_in_addon = relativize_path(file_path, addon_path)
                .context("failed to relativize path of generated file within add-on directory")?;
            info!(" * generated {path_in_addon:?} for {game_type}");
            generated_files.push((path_in_addon, Some(game_type)));
        }
    }

    // add generated files to toc (also, clear old generated-file listings)
    let toc_path = addon_path.join(format!("{}.toc", config.addon_name));
    if !toc_path.is_file() {
        bail!("expected {toc_path:?} to be the path to the add-on toc, but was not a file");
    }
    let toc_content: Vec<String> =
        read_toc_without_generated_inclusions(&config.generated_dir, &toc_path)?;
    trace!("toc_content = {toc_content:#?}");
    write_toc(&toc_path, &toc_content, &generated_files)
        .with_context(|| format!("failed to write new toc file to {toc_path:?}"))?;

    Ok(())
}

fn generate_init_playlists_lua(
    res: &Resources,
    mut w: impl std::io::Write,
    table_name: impl AsRef<str>,
    playlists: &AnimationPlaylists,
) -> Result<()> {
    write_lua_file_comment(&mut w)?;
    // define each playlist
    for (i, (playlist, models)) in playlists.iter().enumerate() {
        if models.is_empty() {
            continue;
        }
        let entries: Box<[String]> = playlist
            .0
            .iter()
            .map(lua_table_entry_for_playlist)
            .collect();
        writeln!(w, "local t{i}={{{}}}", entries.join(","))?;
    }
    // initialize table of model file-data id:s mapped to playlist
    writeln!(w, "select(2,...).{}={{", table_name.as_ref())?;
    for (i, (_, models)) in playlists.iter().enumerate() {
        for &fdid in models {
            write!(w, "[{fdid}]=t{i},")?;
            if let Some(model_name) = res.fdid_name_maybe(fdid) {
                write!(w, "--{model_name}")?;
            }
            writeln!(w, "")?;
        }
    }
    writeln!(w, "}}")?;
    Ok(())
}

fn generate_append_playlists_lua(
    res: &Resources,
    mut w: impl std::io::Write,
    table_name: impl AsRef<str>,
    playlists: &AnimationPlaylists,
) -> Result<()> {
    write_lua_file_comment(&mut w)?;
    writeln!(w, "local t=select(2,...).{}", table_name.as_ref())?;
    for (playlist, models) in playlists {
        if models.is_empty() {
            continue;
        }
        writeln!(w, "do")?;
        let entries: Box<[String]> = playlist
            .0
            .iter()
            .map(lua_table_entry_for_playlist)
            .collect();
        writeln!(w, "local u={{{}}}", entries.join(","))?;
        for &fdid in models {
            write!(w, "t[{fdid}]=u")?;
            if let Some(model_name) = res.fdid_name_maybe(fdid) {
                write!(w, "--{model_name}")?;
            }
            writeln!(w, "")?;
        }
        writeln!(w, "end")?;
    }
    Ok(())
}

fn write_lua_file_comment(mut w: impl std::io::Write) -> Result<()> {
    writeln!(
        w,
        "-- animation-playlist overrides, generated by `{}`",
        module_path!()
    )?;
    Ok(())
}

fn lua_table_entry_for_playlist((variation_id, data): (&u16, &AnimationVariationData)) -> String {
    let &AnimationVariationData {
        probability_per_mille,
    } = data;
    // not sure whether an int in [0, 1000] divided by 1000 can end up with a bunch of decimals, but
    // may as well strangle the possibility here
    let probability_str = format!("{:.2?}", f32::from(probability_per_mille) / 1000.0);
    let probability_str = probability_str.trim_end_matches("0").trim_end_matches(".");
    format!("[{variation_id}]={probability_str}",)
}

fn read_toc_without_generated_inclusions(
    generated_dir: &str,
    file_path: impl AsRef<Path>,
) -> Result<Vec<String>> {
    let file_path: &Path = file_path.as_ref();
    let mut content: Vec<String> = Vec::new();
    let file = fs::File::open(file_path)
        .with_context(|| format!("failed to open add-on toc file: {file_path:?}"))?;
    for line in BufReader::new(file).lines() {
        let line = line.context("io error reading line from add-on toc")?;
        if line.starts_with(&format!("{generated_dir}/")) {
            continue;
        }
        content.push(line);
    }
    Ok(content)
}

fn write_toc(
    file_path: impl AsRef<Path>,
    toc_content: &[String],
    generated_files: &[(Box<Path>, Option<&str>)],
) -> Result<()> {
    use std::io::Write;
    let file_path: &Path = file_path.as_ref();

    let index_after_directives = toc_content
        .iter()
        .position(|line| !line.trim_start().starts_with("#"))
        .ok_or_else(|| anyhow!("could not find any included files in add-on toc"))?;

    let file = fs::File::create(file_path)
        .with_context(|| format!("failed to open add-on toc file as writable: {file_path:?}"))?;
    let mut w = BufWriter::new(file);
    for line in &toc_content[..index_after_directives] {
        writeln!(w, "{line}").context("failed to write line to add-on toc file")?;
    }
    for (path_in_addon, game_type) in generated_files {
        let path_str = path_in_addon
            .components()
            .map(std::path::Component::as_os_str)
            .map(std::ffi::OsStr::to_str)
            .map(|option| {
                option.expect("illegal state: relative generated-file path was not even utf8")
            })
            .collect::<Box<[&str]>>()
            .join("/");
        let file_directive = game_type
            .map(str::to_lowercase)
            .map(|s| format!(" [AllowLoadGameType {s}]"))
            .unwrap_or("".to_owned());
        writeln!(w, "{path_str}{file_directive}")
            .context("failed to write line to add-on toc file")?;
    }
    for line in &toc_content[index_after_directives..] {
        writeln!(w, "{line}").context("failed to write line to add-on toc file")?;
    }
    w.flush()
        .context("failed to flush written add-on toc file")?;
    Ok(())
}

fn group_playlists_by_game_type_filter<'a>(
    res: &'a Resources,
    data_per_model: BTreeMap<u32, HashMap<Option<AnimationPlaylistData>, BTreeSet<&'a Product>>>,
) -> BTreeMap<Option<&'a str>, BTreeMap<AnimationPlaylistData, BTreeSet<u32>>> {
    let game_type_families: HashMap<&str, BTreeSet<&Product>> = res.game_type_families();
    let mut result: BTreeMap<Option<&str>, BTreeMap<AnimationPlaylistData, BTreeSet<u32>>> =
        BTreeMap::new();
    for (fdid, products_by_playlist) in data_per_model {
        // only one playlist ==> applies to all game types ==> do not filter by game type at all
        if products_by_playlist.is_empty() {
            continue;
        } else if products_by_playlist.len() == 1 {
            for (playlist, _) in products_by_playlist {
                if let Some(playlist) = playlist {
                    result
                        .entry(None)
                        .or_default()
                        .entry(playlist)
                        .or_default()
                        .insert(fdid);
                }
            }
            continue;
        }
        // otherwise, for each game-type family, check whether playlist is the same within that
        // family, in which case the playlist can be family-wide
        for (&family, products_in_family) in &game_type_families {
            let playlists_in_family: HashMap<&Option<AnimationPlaylistData>, HashSet<&Product>> =
                products_by_playlist
                    .iter()
                    .filter_map(|(playlist, products)| {
                        let products_in_family_for_playlist: HashSet<&Product> =
                            products_in_family.intersection(products).copied().collect();
                        if products_in_family_for_playlist.is_empty() {
                            None
                        } else {
                            Some((playlist, products_in_family_for_playlist))
                        }
                    })
                    .collect();
            if playlists_in_family.is_empty() {
                continue;
            } else if playlists_in_family.len() == 1 {
                // same one playlist in family
                for (playlist, _) in &playlists_in_family {
                    if let Some(playlist) = playlist {
                        result
                            .entry(Some(family))
                            .or_default()
                            .entry(playlist.clone())
                            .or_default()
                            .insert(fdid);
                    }
                }
            } else {
                // otherwise, playlist must be defined per game
                for (playlist, products) in &playlists_in_family {
                    if let Some(playlist) = playlist {
                        for product in products {
                            result
                                .entry(Some(&*product.game_type))
                                .or_default()
                                .entry(playlist.clone())
                                .or_default()
                                .insert(fdid);
                        }
                    }
                }
            }
        }
    }
    result
}

fn relativize_path(full: impl AsRef<Path>, base: impl AsRef<Path>) -> Result<Box<Path>> {
    let full = full.as_ref();
    let base = base.as_ref();
    Ok(full
        .canonicalize()
        .with_context(|| format!("failed to canonicalize path: {full:?}"))?
        .strip_prefix(
            base.canonicalize()
                .with_context(|| format!("failed to canonicalize path: {base:?}"))?,
        )
        .expect("illegal state: generated-code path was somehow not under add-on path")
        .into())
}

impl From<AnimationPlaylist<'_>> for AnimationPlaylistData {
    fn from(value: AnimationPlaylist) -> Self {
        let values = value
            .variations
            .into_iter()
            .filter_map(filter_map_from_variation_data)
            .collect();
        Self(values)
    }
}

impl From<&AnimationPlaylist<'_>> for AnimationPlaylistData {
    fn from(value: &AnimationPlaylist) -> Self {
        let values = value
            .variations
            .iter()
            .map(|(k, v)| (*k, *v))
            .filter_map(filter_map_from_variation_data)
            .collect();
        Self(values)
    }
}

fn filter_map_from_variation_data(
    (variation_id, playlist): (u16, AnimationVariation),
) -> Option<(u16, AnimationVariationData)> {
    // the add-on animation-override system does not require a probability for 0: any remaining
    // probability is by definition for variation 0
    if variation_id == 0 {
        None
    } else {
        let data = AnimationVariationData {
            probability_per_mille: playlist.probability_per_mille,
        };
        Some((variation_id, data))
    }
}
