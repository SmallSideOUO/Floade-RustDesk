use hbb_common::{anyhow::{bail, Context}, config::{self, Config, Config2}, toml, ResultType};

pub fn existing_id(id: &str) -> bool {
    id.parse::<u64>().ok().is_some_and(|id| (1_000_000_000..2_000_000_000).contains(&id))
}

// The upstream timestamp rule cannot migrate a freshly generated portable identity.
// Run only for the independent Floade profile during its administrator-approved installer.
pub fn import_config(source: &str) -> Option<ResultType<()>> {
    if config::APP_NAME.read().unwrap().as_str() != "FloadeRemote" { return None; }
    Some((|| {
        let path = std::path::PathBuf::from(source);
        if !path.is_absolute() || path.file_name().and_then(|name| name.to_str()) != Some("FloadeRemote.toml") {
            bail!("Expected an absolute Floade configuration path");
        }
        let text = std::fs::read_to_string(&path).context("Read source identity")?;
        let identity: Config = toml::from_str(&text).context("Parse source identity")?;
        if identity.is_empty() { bail!("Source identity is empty"); }
        let options_path = path.with_file_name("FloadeRemote2.toml");
        let text = std::fs::read_to_string(options_path).context("Read source preferences")?;
        let options: Config2 = toml::from_str(&text).context("Parse source preferences")?;
        config::store_path(Config::file(), identity)?;
        config::store_path(Config2::file(), options)?;
        Ok(())
    })())
}

#[cfg(test)]
mod tests {
    #[test]
    fn installed_profile_retains_an_existing_floade_identity() {
        assert!(super::existing_id("1370592362"));
        assert!(super::existing_id("1157168970"));
        assert!(!super::existing_id("493573208"));
        assert!(!super::existing_id(""));
    }
}
