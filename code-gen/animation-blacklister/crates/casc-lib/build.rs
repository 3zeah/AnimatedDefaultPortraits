use std::env;
use std::path::PathBuf;

fn main() {
    println!(r"cargo:rustc-link-search=D:\g\o\CascLib\bin\CascLib_dll\x64\Release");
    println!("cargo:rustc-link-lib=CascLib");
    let bindings = bindgen::Builder::default()
        .header(r"D:\g\o\CascLib\src\CascLib.h")
        .allowlist_type("CASC_STORAGE_PRODUCT")
        .allowlist_type("CASC_FILE_INFO_CLASS")
        .allowlist_type("CASC_FILE_FULL_INFO")
        .allowlist_type("CASC_FILE_SPAN_INFO")
        .allowlist_type("CASC_FIND_DATA")
        .allowlist_var("ERROR_.*")
        .allowlist_var("CASC_OPEN_BY_FILEID")
        .allowlist_var("CASC_OPEN_BY_EKEY")
        .allowlist_var("FILE_BEGIN")
        .allowlist_var("FILE_CURRENT")
        .allowlist_var("FILE_END")
        .allowlist_function("GetCascError")
        .allowlist_function("CascOpenStorage")
        .allowlist_function("CascCloseStorage")
        .allowlist_function("CascGetStorageInfo")
        .allowlist_function("CascImportKeysFromFile")
        .allowlist_function("CascFindFirstFile")
        .allowlist_function("CascFindNextFile")
        .allowlist_function("CascGetFileInfo")
        .allowlist_function("CascGetFileSize64")
        .allowlist_function("CascSetFilePointer64")
        .allowlist_function("CascOpenFile")
        .allowlist_function("CascCloseFile")
        .allowlist_function("CascReadFile")
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("failed to generate bindings");
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_dir.join("casc_lib.rs"))
        .expect("failed to write bindings");
}
