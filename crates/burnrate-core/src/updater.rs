//! Finding and verifying a newer release.
//!
//! Asks GitHub for the latest release, picks the arm64 zip, and verifies the
//! download against the release's own `SHA256SUMS` before it is allowed anywhere
//! near the running bundle. Deliberately not Sparkle: these are ad-hoc signed
//! builds, which Sparkle cannot validate against an update feed.
//!
//! Only the *decision* and the *verification* live here, because both are pure
//! and worth testing. Unpacking, swapping the bundle and relaunching are OS
//! integration and live in `src-tauri`.
//!
//! Nothing is installed unless the checksum matches: a release that publishes no
//! `SHA256SUMS`, or does not list the file being installed, is refused rather
//! than trusted.

use std::collections::HashMap;

use sha2::{Digest, Sha256};

use crate::providers::HttpClient;

/// Where the latest release is asked for.
pub const LATEST_RELEASE_API: &str =
    "https://api.github.com/repos/RichardODonoghue/burnrate/releases/latest";
/// Opened when this platform cannot install in place.
pub const RELEASES_PAGE: &str = "https://github.com/RichardODonoghue/burnrate/releases/latest";
/// The asset the download is checked against.
pub const CHECKSUM_ASSET: &str = "SHA256SUMS";
/// Re-check at most this often while running.
pub const CHECK_INTERVAL_SECONDS: i64 = 24 * 3600;

/// One downloadable file on a release.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub name: String,
    pub url: String,
}

/// A newer release, with the zip already chosen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Release {
    /// `tag_name` with any `v` and suffix stripped, for comparison and display.
    pub version: String,
    pub tag: String,
    pub zip: Asset,
    /// `None` when the release published no `SHA256SUMS` — which makes it
    /// unverifiable, and therefore uninstallable.
    pub checksums: Option<Asset>,
    /// The release's web page, for platforms that cannot install in place.
    pub page: String,
}

/// `"v0.2.0"` / `"1.2.3-beta.1"` → `"0.2.0"` / `"1.2.3"`.
pub fn normalized_version(tag: &str) -> String {
    let trimmed = tag.strip_prefix('v').unwrap_or(tag);
    trimmed.split('-').next().unwrap_or(trimmed).to_string()
}

/// Semver-ish comparison of dotted numeric versions.
///
/// Missing components count as 0, so `"0.2" == "0.2.0"` and `"0.10" > "0.9"` —
/// the latter being the whole point, since a lexical comparison gets it backwards
/// and would refuse a real update.
pub fn is_newer(candidate: &str, current: &str) -> bool {
    let candidate = components(candidate);
    let current = components(current);
    for index in 0..candidate.len().max(current.len()) {
        let a = candidate.get(index).copied().unwrap_or(0);
        let b = current.get(index).copied().unwrap_or(0);
        if a != b {
            return a > b;
        }
    }
    false
}

fn components(version: &str) -> Vec<u64> {
    normalized_version(version)
        .split('.')
        .map(|part| part.parse().unwrap_or(0))
        .collect()
}

/// Parses `shasum -a 256` output: `"<hash>  <filename>"` per line.
///
/// The digest is lowercased and the filename's leading `*` stripped, because
/// `shasum` writes `*` in binary mode while GNU `sha256sum` does not — the two
/// forms mean the same file.
pub fn parse_checksums(text: &str) -> HashMap<String, String> {
    let mut result = HashMap::new();
    for line in text.lines() {
        let mut parts = line.split_whitespace();
        let (Some(hash), Some(name)) = (parts.next(), parts.next()) else {
            continue;
        };
        // The hash must look like one: `line.split_whitespace()` on prose gives
        // two words and would otherwise register "not-a-hash" as a filename.
        if hash.len() != 64 || !hash.chars().all(|c| c.is_ascii_hexdigit()) {
            continue;
        }
        result.insert(
            name.trim_start_matches('*').to_string(),
            hash.to_lowercase(),
        );
    }
    result
}

/// The arm64 zip, preferring an exact architecture match.
///
/// Prefers the arm64 asset and falls back to any zip, so an x64 or universal
/// asset would not be ignored.
pub fn select_zip_asset(assets: &[Asset]) -> Option<Asset> {
    let zips: Vec<&Asset> = assets
        .iter()
        .filter(|asset| asset.name.to_lowercase().ends_with(".zip"))
        .collect();
    zips.iter()
        .find(|asset| asset.name.to_lowercase().contains("arm64"))
        .or_else(|| zips.first())
        .map(|asset| (*asset).clone())
}

/// Parses the GitHub `releases/latest` payload.
///
/// `None` when the release carries no usable zip, which is the same as having
/// nothing to offer.
pub fn parse_release(json: &[u8]) -> Option<Release> {
    let value: serde_json::Value = serde_json::from_slice(json).ok()?;
    let tag = value.get("tag_name")?.as_str()?.to_string();
    let page = value
        .get("html_url")
        .and_then(|value| value.as_str())
        .unwrap_or(RELEASES_PAGE)
        .to_string();
    let assets: Vec<Asset> = value
        .get("assets")?
        .as_array()?
        .iter()
        .filter_map(|asset| {
            Some(Asset {
                name: asset.get("name")?.as_str()?.to_string(),
                url: asset.get("browser_download_url")?.as_str()?.to_string(),
            })
        })
        .collect();

    let zip = select_zip_asset(&assets)?;
    let checksums = assets
        .into_iter()
        .find(|asset| asset.name == CHECKSUM_ASSET);
    Some(Release {
        version: normalized_version(&tag),
        tag,
        zip,
        checksums,
        page,
    })
}

/// The hex SHA-256 of `bytes`.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

/// The outcome of checking a download against the release's `SHA256SUMS`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Checksum {
    Matches,
    /// The release published no sums, or none for this file.
    NotPublished,
    Mismatch {
        expected: String,
        actual: String,
    },
}

/// Verifies `bytes` as `name` against the text of a `SHA256SUMS` file.
pub fn check_download(name: &str, bytes: &[u8], sums: &str) -> Checksum {
    let parsed = parse_checksums(sums);
    let Some(expected) = parsed.get(name) else {
        return Checksum::NotPublished;
    };
    let actual = sha256_hex(bytes);
    if expected.eq_ignore_ascii_case(&actual) {
        Checksum::Matches
    } else {
        Checksum::Mismatch {
            expected: expected.clone(),
            actual,
        }
    }
}

/// Asks GitHub for the latest release. `Ok(None)` when there is none.
///
/// The HTTP client reports non-2xx as a message rather than a status, so a 404 —
/// "no releases yet", or the repository moved — is recognised by its text and is
/// not an error.
pub fn fetch_latest(client: &dyn HttpClient) -> Result<Option<Release>, String> {
    match client.get(
        LATEST_RELEASE_API,
        "",
        &[("Accept", "application/vnd.github+json")],
    ) {
        Ok(body) => Ok(parse_release(body.as_bytes())),
        Err(message) if message.contains("404") => Ok(None),
        Err(message) => Err(message),
    }
}

/// Downloads the release's zip and verifies it against the release's own sums.
///
/// Refuses to hand back bytes that are not verified: an unverifiable release is
/// a failure, not a warning.
pub fn download_verified(client: &dyn HttpClient, release: &Release) -> Result<Vec<u8>, String> {
    let Some(checksums) = &release.checksums else {
        return Err(format!(
            "this release publishes no {CHECKSUM_ASSET}, so the download cannot be verified"
        ));
    };
    let sums = client.get(&checksums.url, "", &[])?;
    let bytes = client.get_bytes(&release.zip.url, &[])?;
    match check_download(&release.zip.name, &bytes, &sums) {
        Checksum::Matches => Ok(bytes),
        Checksum::NotPublished => Err(format!(
            "{} is not listed in {CHECKSUM_ASSET}, so the download cannot be verified",
            release.zip.name
        )),
        Checksum::Mismatch { expected, actual } => Err(format!(
            "checksum mismatch, so the download was refused (expected {}, got {})",
            first_12(&expected),
            first_12(&actual)
        )),
    }
}

/// Only ever used to shorten a hex digest in a message, never to index bytes.
fn first_12(value: &str) -> String {
    value.chars().take(12).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::providers::HttpClient;

    fn asset(name: &str) -> Asset {
        Asset {
            name: name.to_string(),
            url: format!("https://example.com/{name}"),
        }
    }

    // ---- version comparison, ported from `UpdaterTests` ----

    #[test]
    fn normalizes_tags() {
        assert_eq!(normalized_version("v0.2.0"), "0.2.0");
        assert_eq!(normalized_version("0.2.0"), "0.2.0");
        assert_eq!(normalized_version("v1.2.3-beta.1"), "1.2.3");
    }

    #[test]
    fn newer_versions_are_detected() {
        assert!(is_newer("0.2.1", "0.2.0"));
        assert!(is_newer("v0.3.0", "0.2.9"));
        assert!(is_newer("1.0.0", "0.9.9"));
        assert!(is_newer("0.10", "0.9"), "numeric, not lexical");
        assert!(is_newer("0.2.1", "0.2"));
    }

    #[test]
    fn same_or_older_versions_are_rejected() {
        assert!(!is_newer("0.2.0", "0.2.0"));
        assert!(!is_newer("0.2", "0.2.0"), "a missing component is zero");
        assert!(!is_newer("0.1.9", "0.2.0"));
        assert!(!is_newer("v0.2.0", "0.2.0"));
    }

    // ---- checksum parsing ----

    #[test]
    fn parses_sha256sums() {
        let text = "\
aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa  BurnRate-0.2.0-arm64.zip
bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb *BurnRate-0.2.0-arm64.dmg
";
        let parsed = parse_checksums(text);
        assert_eq!(
            parsed.get("BurnRate-0.2.0-arm64.zip").map(String::as_str),
            Some("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        );
        // The `*` is `shasum`'s binary-mode marker, not part of the filename.
        assert_eq!(
            parsed.get("BurnRate-0.2.0-arm64.dmg").map(String::as_str),
            Some("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        );
    }

    #[test]
    fn ignores_malformed_checksum_lines() {
        assert!(parse_checksums("\nnot-a-hash\n").is_empty());
        // Two words that are not a digest must not register.
        assert!(parse_checksums("some prose here\n").is_empty());
        // And the digest has to be the right shape.
        assert!(parse_checksums("abcd  file.zip\n").is_empty());
    }

    // ---- asset selection ----

    #[test]
    fn prefers_the_arm64_zip() {
        let assets = vec![
            asset("BurnRate-0.2.1-arm64.dmg"),
            asset("BurnRate-0.2.1-arm64.zip"),
            asset("BurnRate-0.2.1-x86_64.zip"),
        ];
        assert_eq!(
            select_zip_asset(&assets).map(|a| a.name),
            Some("BurnRate-0.2.1-arm64.zip".to_string())
        );
    }

    #[test]
    fn falls_back_to_any_zip() {
        assert_eq!(
            select_zip_asset(&[asset("BurnRate.zip")]).map(|a| a.name),
            Some("BurnRate.zip".to_string())
        );
        assert!(select_zip_asset(&[]).is_none());
        // A release with no zip has nothing to install.
        assert!(select_zip_asset(&[asset("SHA256SUMS")]).is_none());
    }

    // ---- release parsing ----

    #[test]
    fn parses_a_release_payload() {
        let json = br#"{
            "tag_name": "v0.8.1",
            "html_url": "https://github.com/RichardODonoghue/burnrate/releases/tag/v0.8.1",
            "assets": [
                {"name": "BurnRate-0.8.1-amd64.deb", "browser_download_url": "https://example.com/a.deb"},
                {"name": "BurnRate-0.8.1-arm64.zip", "browser_download_url": "https://example.com/a.zip"},
                {"name": "SHA256SUMS", "browser_download_url": "https://example.com/sums"}
            ]
        }"#;
        let release = parse_release(json).expect("parses");
        assert_eq!(release.version, "0.8.1");
        assert_eq!(release.tag, "v0.8.1");
        assert_eq!(release.zip.name, "BurnRate-0.8.1-arm64.zip");
        assert_eq!(
            release.checksums.map(|asset| asset.name),
            Some("SHA256SUMS".to_string())
        );
        assert!(release.page.contains("v0.8.1"));
    }

    #[test]
    fn a_release_without_a_zip_is_not_offered() {
        let json = br#"{"tag_name":"v9.9.9","html_url":"https://example.com","assets":[{"name":"SHA256SUMS","browser_download_url":"https://example.com/s"}]}"#;
        assert!(parse_release(json).is_none());
    }

    #[test]
    fn malformed_json_is_not_offered() {
        assert!(parse_release(b"not json").is_none());
    }

    // ---- verification ----

    #[test]
    fn sha256_matches_the_known_vector() {
        assert_eq!(
            sha256_hex(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }

    #[test]
    fn a_matching_download_verifies() {
        let digest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
        assert_eq!(
            check_download("BurnRate.zip", b"abc", &format!("{digest}  BurnRate.zip\n")),
            Checksum::Matches
        );
        // The digest's case does not matter — `shasum` writes lower case, other
        // tools upper — but the filename's does, because it names the asset.
        assert_eq!(
            check_download(
                "BurnRate.zip",
                b"abc",
                &format!("{}  BurnRate.zip\n", digest.to_uppercase())
            ),
            Checksum::Matches
        );
    }

    #[test]
    fn a_tampered_download_is_refused() {
        let sums = format!(
            "{}  BurnRate.zip\n",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        match check_download("BurnRate.zip", b"abd", &sums) {
            Checksum::Mismatch { expected, actual } => {
                assert!(expected.starts_with("ba7816bf"));
                assert!(!actual.starts_with("ba7816bf"));
            }
            other => panic!("expected a mismatch, got {other:?}"),
        }
    }

    #[test]
    fn a_file_missing_from_the_sums_is_refused() {
        let sums = format!(
            "{}  SomethingElse.zip\n",
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
        assert_eq!(
            check_download("BurnRate.zip", b"abc", &sums),
            Checksum::NotPublished
        );
    }

    // ---- fetch, against a stub ----

    struct Stub {
        body: Result<String, String>,
    }

    impl HttpClient for Stub {
        fn get(
            &self,
            _url: &str,
            _bearer: &str,
            _headers: &[(&str, &str)],
        ) -> Result<String, String> {
            match &self.body {
                Ok(body) => Ok(body.clone()),
                Err(message) => Err(message.clone()),
            }
        }
    }

    #[test]
    fn no_releases_is_not_an_error() {
        let client = Stub {
            body: Err("HTTP 404".into()),
        };
        assert_eq!(fetch_latest(&client), Ok(None));
    }

    #[test]
    fn a_network_failure_is_reported() {
        let client = Stub {
            body: Err("connection refused".into()),
        };
        assert_eq!(fetch_latest(&client), Err("connection refused".to_string()));
    }

    #[test]
    fn a_latest_release_is_parsed_through_the_client() {
        let client = Stub {
            body: Ok(r#"{"tag_name":"v1.0.0","html_url":"https://example.com","assets":[{"name":"BurnRate-1.0.0-arm64.zip","browser_download_url":"https://example.com/z"}]}"#.into()),
        };
        let release = fetch_latest(&client).expect("ok").expect("a release");
        assert_eq!(release.version, "1.0.0");
        assert!(release.checksums.is_none(), "none published");
    }

    /// An unverifiable release is refused rather than installed.
    #[test]
    fn a_release_without_sums_cannot_be_downloaded() {
        let client = Stub {
            body: Ok(String::new()),
        };
        let release = Release {
            version: "1.0.0".into(),
            tag: "v1.0.0".into(),
            zip: asset("BurnRate-1.0.0-arm64.zip"),
            checksums: None,
            page: "https://example.com".into(),
        };
        let error = download_verified(&client, &release).expect_err("refused");
        assert!(error.contains("cannot be verified"), "got {error}");
    }
}
