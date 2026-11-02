mod cache;
pub mod csv;
mod path;

use std::collections::{BTreeSet, HashMap, HashSet, hash_map};
use std::convert::Infallible;
use std::path::{Path, PathBuf};
use std::{cell, error, fmt, fs, io, num};

use LoadResourcesError::*;
use casc_lib::{CascLibOrInvalidPathError, CascStorage};
use csv::CsvParseError;
use log::{info, trace};
use regex::regex;
use serde::Deserialize;
use thiserror::Error;

#[derive(Deserialize, Debug)]
pub struct Config {
    pub listfile_path: Box<Path>,
    pub encryption_keys_path: Box<Path>,
    pub model_file_data_dir: Box<Path>,
    pub products: Box<[ProductDefinition]>,
}

#[derive(Deserialize, Debug)]
pub struct ProductDefinition {
    pub name: Box<str>,
    pub game_type: Box<str>,
    pub game_type_family: Box<str>,
    pub path: Box<Path>,
}

pub struct Resources {
    products: Box<[Product]>,
    listfile: HashMap<u32, String>,
    encryption_keys: PathBuf,
    model_file_data: HashMap<Product, Box<Path>>,
}

#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct ModelId<'a> {
    pub fdid: u32,
    pub product: &'a Product,
    pub human_name: &'a str,
}

#[derive(Clone)]
pub struct Product {
    pub game_type: Box<str>,
    pub game_type_family: Box<str>,
    name: Box<str>,
    rank: usize,
    path: Box<Path>,
}

pub type BuildVersion = String;

#[derive(Error, Debug)]
pub enum LoadResourcesError {
    #[error(r#"product path did not exist or was not a directory: {0}"#)]
    ProductNotFound(Box<Path>),
    #[error(r#"product "{0}" did not exist for installation in {1}"#)]
    // todo. surely not path display
    ProductNotInInstallation(Box<str>, Box<Path>),
    #[error(r#"error parsing .build.info from {0}: {1}"#)]
    BuildInfoParseError(PathBuf, #[source] CsvParseError),
    #[error(r#"error parsing listfile.csv from {0}: {1}"#)]
    ListFileParseError(PathBuf, #[source] CsvParseOrColumnTypeError),
    #[error(r#"io error listing resources (in "{0:?}"): {1}"#)]
    ErrorListingResources(Box<Path>, #[source] io::Error),
    #[error(r#"io error reading or writing resource, {0}: {1}"#)]
    ResourceIoError(PathBuf, #[source] io::Error),
    #[error(r#"network error downloading resource: {0}"#)]
    DownloadError(#[from] reqwest::Error),
}

#[derive(Debug)]
pub enum CsvParseOrColumnTypeError {
    ParseIntError(num::ParseIntError),
    CsvParseError(csv::CsvParseError),
}

impl Resources {
    pub fn first_product(&self) -> Option<&Product> {
        self.products.get(0)
    }

    pub fn product_by_name(&self, name: impl AsRef<str>) -> Option<&Product> {
        for product in &self.products {
            if &*product.name == name.as_ref() {
                return Some(product);
            }
        }
        None
    }

    pub fn product_by_game_type(&self, game_type: impl AsRef<str>) -> Option<&Product> {
        for product in &self.products {
            if &*product.game_type == game_type.as_ref() {
                return Some(product);
            }
        }
        None
    }

    pub fn all_products(&self) -> &[Product] {
        &self.products
    }

    pub fn game_type_families(&self) -> HashMap<&str, BTreeSet<&Product>> {
        let mut result: HashMap<&str, BTreeSet<&Product>> = HashMap::new();
        for product in &self.products {
            result
                .entry(&*product.game_type_family)
                .or_default()
                .insert(product);
        }
        result
    }

    pub fn fdid_name(&self, fdid: u32) -> &str {
        self.fdid_name_maybe(fdid).unwrap_or("<not in listfile>")
    }

    pub fn fdid_human_name(&self, fdid: u32) -> &str {
        self.fdid_human_name_maybe(fdid)
            .unwrap_or("<not in listfile>")
    }

    pub fn fdid_name_maybe(&self, fdid: u32) -> Option<&str> {
        self.listfile.get(&fdid).map(String::as_ref)
    }

    pub fn fdid_human_name_maybe(&self, fdid: u32) -> Option<&str> {
        self.fdid_name_maybe(fdid)
            .map(|path| path.rsplit_once("/").map(|(_, name)| name).unwrap_or(path))
    }

    pub fn model_id<'a>(&'a self, fdid: u32, product: &'a Product) -> ModelId<'a> {
        ModelId {
            fdid,
            product,
            human_name: self.fdid_human_name(fdid),
        }
    }

    pub fn open_local_storage(
        &self,
        product: &Product,
    ) -> Result<CascStorage, CascLibOrInvalidPathError> {
        let storage = CascStorage::open_local(&product.path, Some(&*product.name))?;
        storage.import_keys_from_file(&self.encryption_keys)?;
        Ok(storage)
    }

    pub fn load_model_file_ids(
        &self,
        product: &Product,
    ) -> Result<BTreeSet<u32>, CsvParseOrColumnTypeError> {
        let file_path = self
            .model_file_data
            .get(product)
            // product must exist since the wrapper type, `Product`, is only constructed internally
            .unwrap_or_else(|| panic!("product {product} had no model file data somehow"));
        Ok(parse_model_file_data_list(file_path)?)
    }

    pub fn load(config: Config) -> Result<Self, LoadResourcesError> {
        let products = Self::init_products(config.products);
        trace!("products: {products:#?}");
        for product in &products {
            if !product.path.is_dir() {
                return Err(LoadResourcesError::ProductNotFound(product.path.clone()));
            }
        }
        let product_versions: HashMap<&Product, BuildVersion> =
            parse_all_product_versions(&products)?;
        trace!("product versions: {product_versions:#?}");

        let listfile = Self::load_listfile(config.listfile_path)?;
        let encryption_keys = Self::download_encryption_keys(config.encryption_keys_path)?;
        let model_file_data =
            Self::resolve_model_file_data(config.model_file_data_dir, product_versions)?;
        trace!("ModelFileData files: {model_file_data:#?}");

        Ok(Self {
            products,
            listfile,
            encryption_keys,
            model_file_data,
        })
    }

    fn init_products(config: impl IntoIterator<Item = ProductDefinition>) -> Box<[Product]> {
        config
            .into_iter()
            .enumerate()
            .map(|(i, definition)| Product {
                name: definition.name,
                game_type: definition.game_type,
                game_type_family: definition.game_type_family,
                rank: i,
                path: definition.path,
            })
            .collect()
    }

    fn load_listfile(path: impl AsRef<Path>) -> Result<HashMap<u32, String>, LoadResourcesError> {
        let path = path.as_ref();
        let file_exists = match cache::check_file_cache(path) {
            Ok(ok) => match ok {
                cache::FileCacheValidity::Valid { days } => {
                    if let Some(days) = days {
                        trace!(
                            "skip download: listfile ({path:?}) exists and was valid {days:?} days \
                            ago"
                        );
                    } else {
                        trace!("skip download: listfile ({path:?}) exists");
                    }
                    true
                }
                cache::FileCacheValidity::StaleInCache { days } => {
                    trace!("listfile ({path:?}) exist in cache, but is {days:?} days old");
                    false
                }
                cache::FileCacheValidity::NotInCache => {
                    trace!("listfile ({path:?}) did not exist in cache");
                    false
                }
            },
            Err(err) => {
                return Err(LoadResourcesError::ResourceIoError(path.into(), err));
            }
        };
        let bytes = if !file_exists {
            let network_client = reqwest::blocking::Client::new();
            const URL: &str = "https://github.com/wowdev/wow-listfile/releases/latest/download/\
                               community-listfile-withcapitals.csv";
            info!(r#"listfile not found locally or stale: downloading from "{URL}""#);
            let response = network_client
                .get(URL)
                .send()?
                .error_for_status()?
                .bytes()?;
            if let Err(e) = fs::write(&path, response.clone()) {
                return Err(ResourceIoError(path.into(), e));
            }
            response.into()
        } else {
            trace!("listfile ({path:?}) already exists: loading that");
            match fs::read(&path) {
                Ok(ok) => ok,
                Err(err) => return Err(ResourceIoError(path.into(), err)),
            }
        };
        Ok(parse_listfile(&*bytes).map_err(|e| ListFileParseError(path.into(), e))?)
    }

    fn download_encryption_keys(path: impl AsRef<Path>) -> Result<PathBuf, LoadResourcesError> {
        const URL: &str = r"https://github.com/wowdev/TACTKeys/raw/refs/heads/master/WoW.txt";
        let path = path.as_ref();
        match cache::check_file_cache(path) {
            Ok(ok) => match ok {
                cache::FileCacheValidity::Valid { days } => {
                    if let Some(days) = days {
                        trace!(
                            "skip download: encryption (TACT) keys ({path:?}) exist in cache and \
                            were valid {days:?} days ago"
                        );
                    } else {
                        trace!("skip download: encryption (TACT) keys ({path:?}) were cached");
                    }
                    return Ok(path.into());
                }
                cache::FileCacheValidity::StaleInCache { days } => {
                    trace!(
                        "encryption (TACT) keys ({path:?}) exist in cache, but are {days:?} days \
                        old"
                    );
                }
                cache::FileCacheValidity::NotInCache => {
                    trace!("encryption (TACT) keys ({path:?}) did not exist in cache");
                }
            },
            Err(err) => {
                return Err(LoadResourcesError::ResourceIoError(path.into(), err));
            }
        }
        info!(r#"encryption (TACT) keys not yet cached or stale: downloading from "{URL}""#);
        let network_client = reqwest::blocking::Client::new();
        let response = network_client
            .get(URL)
            .send()?
            .error_for_status()?
            .bytes()?;
        if let Some(dir) = Path::new(path).parent() {
            trace!(r#"ensuring encryption key directory exists: {dir:?}"#);
            if let Err(e) = fs::create_dir_all(dir) {
                return Err(ResourceIoError(dir.into(), e));
            }
        }
        if let Err(e) = fs::write(path, response) {
            return Err(ResourceIoError(path.into(), e));
        }
        Ok(path.into())
    }

    fn resolve_model_file_data(
        dir: impl AsRef<Path>,
        product_versions: HashMap<&Product, BuildVersion>,
    ) -> Result<HashMap<Product, Box<Path>>, LoadResourcesError> {
        // build version -> (game type, model file data path)
        let cached_model_file_data: HashMap<BuildVersion, (Box<str>, Box<Path>)> =
            Self::find_model_file_data_files(&dir)
                .map_err(|e| ErrorListingResources(dir.as_ref().into(), e))?;
        trace!("cached ModelFileData files: {cached_model_file_data:#?}");
        let installed_versions: HashSet<&BuildVersion> = product_versions.values().collect();
        let mut valid_cached_versions: HashSet<BuildVersion> = HashSet::new();
        let mut all_model_file_data: HashMap<Product, Box<Path>> = HashMap::new();
        for (cached_version, (game_type, path)) in cached_model_file_data {
            let product = product_versions
                .keys()
                .find(|product| *product.game_type == *game_type);
            if let Some(&product) = product {
                if installed_versions.contains(&cached_version) {
                    valid_cached_versions.insert(cached_version);
                    all_model_file_data.insert(product.clone(), path);
                    continue;
                } else {
                    info!(r#"deleting unused ModelFileData for "{game_type}": {path:?}"#,);
                    fs::remove_file(&path).map_err(|e| ResourceIoError(path.to_path_buf(), e))?;
                }
            } else {
                trace!(r#"ignoring due to game type ("{game_type}") not present: {path:?}"#);
            }
        }
        let network_client = cell::LazyCell::new(reqwest::blocking::Client::new);
        for (product, version) in product_versions {
            if valid_cached_versions.contains(&version) {
                trace!("skip download: ModelFileData for {version} is already cached locally");
                continue;
            }
            let url = format!("https://wago.tools/db2/ModelFileData/csv?version={version}");
            info!(r#"ModelFileData for {version} not found locally: downloading from "{url}""#);
            let response = network_client
                .get(&url)
                .send()?
                .error_for_status()?
                .bytes()?;
            let game_type = &product.game_type;
            let file_path = dir
                .as_ref()
                .join(format!("ModelFileData-{game_type}-{version}.csv"));
            if let Err(e) = fs::write(&file_path, &response) {
                return Err(ResourceIoError(file_path, e));
            }
            trace!(r#"download success: {file_path:?} from "{url}""#);
            all_model_file_data.insert(product.clone(), file_path.into_boxed_path());
        }
        Ok(all_model_file_data)
    }

    fn find_model_file_data_files(
        dir: impl AsRef<Path>,
    ) -> io::Result<HashMap<BuildVersion, (Box<str>, Box<Path>)>> {
        let mut result: HashMap<BuildVersion, (Box<str>, Box<Path>)> = HashMap::new();
        for model_file_data_file in fs::read_dir(dir.as_ref())? {
            let file = model_file_data_file?;
            if !file.file_type()?.is_file() {
                continue;
            };
            let file_name = file.file_name().into_string().map_err(|name| {
                io::Error::new(
                    io::ErrorKind::InvalidFilename,
                    format!(r"ModelFileData file name was not unicode: {name:?}"),
                )
            })?;
            let file_name_pattern = regex!(r"^ModelFileData-([\w_]+)-([\d.]+)\.csv$");
            let (game_type, version) = match file_name_pattern.captures(&file_name) {
                Some(captures) => {
                    let (_, [product, version]) = captures.extract();
                    (product, version)
                }
                None => {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidFilename,
                        format!(
                            r#"invalid ModelFileData file name: expected "ModelFileData-<product>-<version>.csv", but got "{file_name}""#
                        ),
                    ));
                }
            };
            result.insert(
                version.to_owned(),
                (game_type.into(), file.path().into_boxed_path()),
            );
        }
        Ok(result)
    }
}

impl fmt::Display for ModelId<'_> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let ModelId {
            fdid,
            product,
            human_name,
        } = self;
        write!(f, r#""{human_name}" ({fdid}) in "{product}""#,)
    }
}

fn parse_listfile(read: impl io::Read) -> Result<HashMap<u32, String>, CsvParseOrColumnTypeError> {
    let list_file: Vec<[String; 2]> = csv::parse_csv(read, ";", None)?;
    trace!("read listfile csv of length {}", list_file.len());
    list_file
        .into_iter()
        .map(parse_listfile_row)
        .collect::<Result<_, _>>()
}

fn parse_listfile_row(row: [String; 2]) -> Result<(u32, String), CsvParseOrColumnTypeError> {
    let [fdid, name] = row;
    Ok((parse_fdid(fdid)?, name))
}

fn parse_all_product_versions(
    products: &[Product],
) -> Result<HashMap<&Product, BuildVersion>, LoadResourcesError> {
    let mut build_versions_cache: HashMap<&Path, HashMap<String, BuildVersion>> = HashMap::new();
    let mut result: HashMap<&Product, BuildVersion> = HashMap::with_capacity(products.len());
    for product in products {
        // product name -> build version
        let build_versions: &HashMap<String, BuildVersion> =
            match build_versions_cache.entry(&product.path) {
                hash_map::Entry::Occupied(occupied) => occupied.into_mut(),
                hash_map::Entry::Vacant(vacant) => {
                    let &path = vacant.key();
                    let entry = parse_product_versions(path)
                        .map_err(|e| BuildInfoParseError(path.into(), e))?;
                    vacant.insert(entry)
                }
            };
        let build_version: BuildVersion = match build_versions.get(&*product.name) {
            Some(some) => some.clone(),
            None => {
                return Err(LoadResourcesError::ProductNotInInstallation(
                    product.name.clone(),
                    product.path.clone(),
                ));
            }
        };
        result.insert(product, build_version);
    }
    Ok(result)
}

fn parse_product_versions<P: AsRef<Path>>(
    game_path: P,
) -> Result<HashMap<String, BuildVersion>, csv::CsvParseError> {
    const FILE_FORMAT: [&str; 15] = [
        "Branch!STRING:0",
        "Active!DEC:1",
        "Build Key!HEX:16",
        "CDN Key!HEX:16",
        "Install Key!HEX:16",
        "IM Size!DEC:4",
        "CDN Path!STRING:0",
        "CDN Hosts!STRING:0",
        "CDN Servers!STRING:0",
        "Tags!STRING:0",
        "Armadillo!STRING:0",
        "Last Activated!STRING:0",
        "Version!STRING:0",
        "KeyRing!HEX:16",
        "Product!STRING:0",
    ];
    let file_path = game_path.as_ref().join(".build.info");
    let file = fs::File::open(file_path).map_err(csv::CsvParseError::from)?;
    let products: Vec<[String; 3]> =
        csv::parse_csv_filtered(file, "|", Some(&FILE_FORMAT), &[14, 1, 12])?;
    trace!("read build info raw csv: {products:?}");
    Ok(products
        .into_iter()
        .filter_map(|[product, activated, version]| {
            if activated == "1" {
                Some((product, version))
            } else {
                None
            }
        })
        .collect())
}

impl fmt::Debug for Resources {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Resources")
            .field("products", &self.products)
            .field("listfile.len()", &self.listfile.len())
            .field("model_file_data", &self.model_file_data)
            .finish()
    }
}

fn parse_model_file_data_list<P: AsRef<Path>>(
    file_path: P,
) -> Result<BTreeSet<u32>, CsvParseOrColumnTypeError> {
    const FILE_FORMAT: [&str; 10] = [
        "GeoBox_0",
        "GeoBox_1",
        "GeoBox_2",
        "GeoBox_3",
        "GeoBox_4",
        "GeoBox_5",
        "FileDataID",
        "Flags",
        "LodCount",
        "ModelResourcesID",
    ];
    let file = fs::File::open(file_path).map_err(csv::CsvParseError::from)?;
    let fdids: Vec<[String; 1]> = csv::parse_csv_filtered(file, ",", Some(&FILE_FORMAT), &[6])?;
    fdids.into_iter().map(parse_fdid_row).collect()
}

fn parse_fdid_row(row: [String; 1]) -> Result<u32, CsvParseOrColumnTypeError> {
    parse_fdid(&row[0])
}

fn parse_fdid(str: impl AsRef<str>) -> Result<u32, CsvParseOrColumnTypeError> {
    str.as_ref()
        .parse::<u32>()
        .map_err(num::ParseIntError::into)
}

impl fmt::Display for Product {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self.game_type, f)
    }
}

impl fmt::Debug for Product {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(&self, f)
    }
}

impl std::cmp::PartialEq for Product {
    fn eq(&self, other: &Self) -> bool {
        self.rank == other.rank
    }
}

impl std::cmp::Eq for Product {}

impl std::hash::Hash for Product {
    fn hash<H: std::hash::Hasher>(&self, state: &mut H) {
        self.rank.hash(state);
    }
}

impl std::cmp::PartialOrd for Product {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.rank.partial_cmp(&other.rank)
    }
}

impl std::cmp::Ord for Product {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.rank.cmp(&other.rank)
    }
}

impl From<Infallible> for LoadResourcesError {
    fn from(_: Infallible) -> Self {
        unreachable!();
    }
}

impl error::Error for CsvParseOrColumnTypeError {
    fn source(&self) -> Option<&(dyn error::Error + 'static)> {
        match self {
            CsvParseOrColumnTypeError::ParseIntError(e) => Some(e),
            CsvParseOrColumnTypeError::CsvParseError(e) => Some(e),
        }
    }
}

impl fmt::Display for CsvParseOrColumnTypeError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CsvParseOrColumnTypeError::ParseIntError(_) => write!(f, "expected int column"),
            CsvParseOrColumnTypeError::CsvParseError(_) => write!(f, "failed to parse csv"),
        }
    }
}

impl From<num::ParseIntError> for CsvParseOrColumnTypeError {
    fn from(value: num::ParseIntError) -> Self {
        CsvParseOrColumnTypeError::ParseIntError(value)
    }
}

impl From<csv::CsvParseError> for CsvParseOrColumnTypeError {
    fn from(value: csv::CsvParseError) -> Self {
        CsvParseOrColumnTypeError::CsvParseError(value)
    }
}
