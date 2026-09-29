//! User settings, persisted as JSON.
//!
//! Ported 1:1 from `Sources/BurnRate/Settings.swift`, including the key names
//! and the legacy-decoding behaviour, so a Swift install's settings migrate
//! across untouched. Swift stored each key as a JSON blob inside UserDefaults;
//! here they are fields of one `settings.json` in the app directory, and
//! `Settings::from_swift_defaults` converts the old blobs.
//!
//! Plan capacities are *not* here: they are predetermined
//! ([`crate::plan_capacities_by_provider_window`]) and have no UI.

use serde::{Deserialize, Serialize};

use crate::alerts::{AlertDefaults, BurnAlert, CostAlert, Milestone};

/// The read-only settings surface the alert notifier needs.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Settings {
    /// Milestone rules, always coalesced to one per provider+window on load.
    pub milestones: Vec<Milestone>,
    /// Provider names with an extra menu-bar widget spawned.
    pub widget_providers: Vec<String>,
    /// Burn-rate alerts: notify on a fast % drop within a trailing window.
    pub burn_alerts: Vec<BurnAlert>,
    /// Per-provider daily spend cap (USD), from local logs.
    pub cost_alerts: Vec<CostAlert>,
    /// Notify on window reset (remaining jumps back up).
    pub notify_on_reset: bool,
    /// Seconds between usage polls.
    pub poll_interval_seconds: u64,
    /// Show the Charts row in the tray menu (Linux/Windows style; the macOS
    /// app has the dashboard instead).
    pub includes_charts: bool,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            milestones: AlertDefaults::milestones(),
            widget_providers: Vec::new(),
            burn_alerts: AlertDefaults::burn_alerts(),
            cost_alerts: Vec::new(),
            notify_on_reset: true,
            poll_interval_seconds: 300,
            includes_charts: cfg!(not(target_os = "macos")),
        }
    }
}

impl Settings {
    /// Coalesces duplicate milestone rules, which is what the Swift store did
    /// on load so one window can never hold two rules.
    pub fn normalised(mut self) -> Self {
        self.milestones = Milestone::coalesce(&self.milestones);
        self
    }

    /// Insert or replace the rule for a provider+window — duplicates impossible.
    pub fn upsert_milestone(&mut self, milestone: Milestone) {
        self.milestones
            .retain(|existing| existing.key() != milestone.key());
        self.milestones.push(milestone);
        self.milestones = Milestone::coalesce(&self.milestones);
    }

    pub fn remove_milestone(&mut self, provider: &str, window_label: &str) {
        self.milestones
            .retain(|m| !(m.provider == provider && m.window_label == window_label));
    }

    pub fn upsert_burn_alert(&mut self, alert: BurnAlert) {
        self.burn_alerts
            .retain(|existing| existing.key() != alert.key());
        self.burn_alerts.push(alert);
    }

    pub fn remove_burn_alert(&mut self, provider: &str, window_label: &str) {
        self.burn_alerts
            .retain(|a| !(a.provider == provider && a.window_label == window_label));
    }

    /// Adds or removes a provider's widget, keeping the list sorted so the tray
    /// order is deterministic.
    pub fn toggle_widget(&mut self, provider: &str) -> bool {
        match self
            .widget_providers
            .iter()
            .position(|existing| existing == provider)
        {
            Some(index) => {
                self.widget_providers.remove(index);
                false
            }
            None => {
                self.widget_providers.push(provider.to_string());
                self.widget_providers.sort();
                true
            }
        }
    }

    /// The quota windows a widget title should prefer, in order.
    pub fn window_labels(&self) -> Vec<String> {
        ["Rolling", "Weekly", "Monthly"]
            .iter()
            .map(|label| label.to_string())
            .collect()
    }

    /// Reads settings from disk, falling back to defaults when absent.
    /// A malformed file is *not* silently discarded: it is reported so the UI
    /// can say so, rather than pretending the user never had settings.
    pub fn load(path: &std::path::Path) -> Result<Self, SettingsError> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let settings: Settings = serde_json::from_str(&text)?;
                Ok(settings.normalised())
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Self::default()),
            Err(error) => Err(SettingsError::Io(error)),
        }
    }

    pub fn save(&self, path: &std::path::Path) -> Result<(), SettingsError> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        let text = serde_json::to_string_pretty(self)?;
        std::fs::write(path, text)?;
        Ok(())
    }

    /// Converts a Swift install's UserDefaults blobs into this struct.
    ///
    /// Swift wrote each field as a separately-encoded JSON blob, so each is
    /// parsed independently and a missing one falls back to the default.
    pub fn from_swift_defaults(
        milestones: Option<&str>,
        widget_providers: Option<&str>,
        burn_alerts: Option<&str>,
        cost_alerts: Option<&str>,
        notify_on_reset: Option<bool>,
    ) -> Self {
        let mut settings = Settings::default();
        if let Some(text) = milestones {
            if let Ok(parsed) = serde_json::from_str::<Vec<Milestone>>(text) {
                settings.milestones = parsed;
            }
        }
        if let Some(text) = widget_providers {
            if let Ok(parsed) = serde_json::from_str::<Vec<String>>(text) {
                settings.widget_providers = parsed;
            }
        }
        if let Some(text) = burn_alerts {
            if let Ok(parsed) = serde_json::from_str::<Vec<BurnAlert>>(text) {
                settings.burn_alerts = parsed;
            }
        }
        if let Some(text) = cost_alerts {
            if let Ok(parsed) = serde_json::from_str::<Vec<CostAlert>>(text) {
                settings.cost_alerts = parsed;
            }
        }
        if let Some(value) = notify_on_reset {
            settings.notify_on_reset = value;
        }
        settings.normalised()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum SettingsError {
    #[error("could not read or write settings: {0}")]
    Io(#[from] std::io::Error),
    #[error("settings file is not valid JSON: {0}")]
    Parse(#[from] serde_json::Error),
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("burnrate-settings-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn defaults_match_the_shipped_alert_rules() {
        let settings = Settings::default();
        assert_eq!(settings.milestones.len(), 3);
        assert_eq!(settings.burn_alerts.len(), 1);
        assert!(settings.notify_on_reset);
        assert!(settings.widget_providers.is_empty());
    }

    /// Round trips through disk, which is what makes settings survive a quit.
    #[test]
    fn saves_and_loads() {
        let dir = temp_dir("roundtrip");
        let path = dir.join("settings.json");
        let settings = Settings {
            widget_providers: vec!["Claude".into()],
            poll_interval_seconds: 60,
            ..Settings::default()
        };
        settings.save(&path).unwrap();

        let loaded = Settings::load(&path).unwrap();
        assert_eq!(loaded.widget_providers, vec!["Claude".to_string()]);
        assert_eq!(loaded.poll_interval_seconds, 60);
    }

    #[test]
    fn missing_file_yields_defaults() {
        let dir = temp_dir("missing");
        let settings = Settings::load(&dir.join("nope.json")).unwrap();
        assert_eq!(settings.milestones, Settings::default().milestones);
    }

    /// A corrupt file is reported, not silently replaced — the user's settings
    /// are recoverable by hand if we say so.
    #[test]
    fn corrupt_file_is_reported() {
        let dir = temp_dir("corrupt");
        let path = dir.join("settings.json");
        std::fs::write(&path, "{ not json").unwrap();
        assert!(matches!(
            Settings::load(&path),
            Err(SettingsError::Parse(_))
        ));
    }

    /// A rule for a window is replaced, never duplicated.
    #[test]
    fn upsert_milestone_replaces_the_window_rule() {
        let mut settings = Settings::default();
        settings.upsert_milestone(Milestone::new("Claude", "Rolling", 5.0));
        let rolling: Vec<_> = settings
            .milestones
            .iter()
            .filter(|m| m.window_label == "Rolling" && m.provider == "Claude")
            .collect();
        assert_eq!(rolling.len(), 1);
        assert_eq!(rolling[0].step, 5.0);
    }

    #[test]
    fn remove_milestone_drops_only_that_window() {
        let mut settings = Settings::default();
        let before = settings.milestones.len();
        settings.remove_milestone("Claude", "Rolling");
        assert_eq!(settings.milestones.len(), before - 1);
        assert!(!settings
            .milestones
            .iter()
            .any(|m| m.provider == "Claude" && m.window_label == "Rolling"));
    }

    /// Toggling a widget is idempotent in the way the UI needs.
    #[test]
    fn toggle_widget_adds_then_removes() {
        let mut settings = Settings::default();
        assert!(settings.toggle_widget("Claude"));
        assert_eq!(settings.widget_providers, vec!["Claude".to_string()]);
        assert!(!settings.toggle_widget("Claude"));
        assert!(settings.widget_providers.is_empty());
    }

    /// Loading a file with duplicate rules coalesces them, as the Swift store did.
    #[test]
    fn load_coalesces_duplicate_rules() {
        let dir = temp_dir("coalesce");
        let path = dir.join("settings.json");
        std::fs::write(
            &path,
            r#"{"milestones":[
                {"provider":"Claude","windowLabel":"Rolling","step":25},
                {"provider":"Claude","windowLabel":"Rolling","step":10}]}"#,
        )
        .unwrap();
        let settings = Settings::load(&path).unwrap();
        let rolling: Vec<_> = settings
            .milestones
            .iter()
            .filter(|m| m.window_label == "Rolling")
            .collect();
        assert_eq!(rolling.len(), 1);
        assert_eq!(rolling[0].step, 10.0, "smallest step survives");
    }

    /// A Swift install's UserDefaults blobs convert cleanly.
    #[test]
    fn migrates_swift_user_defaults() {
        let settings = Settings::from_swift_defaults(
            Some(r#"[{"provider":"Claude","windowLabel":"Weekly","step":20}]"#),
            Some(r#"["Codex"]"#),
            Some(
                r#"[{"provider":"Claude","windowLabel":"Rolling","percentDrop":15,"minutes":30}]"#,
            ),
            Some("[]"),
            Some(false),
        );
        assert_eq!(settings.milestones.len(), 1);
        assert_eq!(settings.milestones[0].window_label, "Weekly");
        assert_eq!(settings.widget_providers, vec!["Codex".to_string()]);
        assert_eq!(settings.burn_alerts.len(), 1);
        assert!(!settings.notify_on_reset);
    }

    /// A legacy fixed-threshold milestone decodes to a step, as in Swift.
    #[test]
    fn legacy_threshold_milestone_decodes_to_step() {
        let settings = Settings::from_swift_defaults(
            Some(r#"[{"provider":"Claude","windowLabel":"Rolling","percentRemaining":50}]"#),
            None,
            None,
            None,
            None,
        );
        assert_eq!(settings.milestones[0].step, 50.0);
    }

    /// Charts is on by default off macOS, matching the Swift `includesCharts`.
    #[test]
    fn charts_default_follows_the_platform() {
        assert_eq!(
            Settings::default().includes_charts,
            cfg!(not(target_os = "macos"))
        );
    }
}
