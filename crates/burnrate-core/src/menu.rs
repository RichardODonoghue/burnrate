//! Tray menu models and the builder that turns usage into rows.
//!
//! Pure, so menu contents are testable with no OS UI. Each platform renders
//! the model (macOS `NSMenu`, Linux DBusMenu, Windows `HMENU`).
//!
//! Ported 1:1 from the Swift app's `StatusMenu.swift`. Parity tests:
//! `StatusMenuTests` — `mainMenuListsProvidersWindowsAndActions`,
//! `widgetMenuEndsWithRemoveAction`,
//! `widgetTitlePrefersMonthlyThenFirstWindow`,
//! `worstRollingRemainingIsMinimumAcrossProviders`, `chartsRowIsOptIn`.

use serde::{Deserialize, Serialize};

use crate::formatting::RelativeTime;
use crate::model::{ProviderUsage, UsageWindow};

/// An action a tray menu row can trigger. The host decides how to perform it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StatusMenuAction {
    OpenDashboard,
    OpenCharts,
    OpenSettings,
    CheckForUpdates,
    InstallUpdate { version: String },
    RemoveWidget { provider: String },
    Quit,
}

/// One row in a tray menu.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum StatusMenuEntry {
    /// Provider heading, e.g. "Claude - Team 5x".
    ProviderHeader {
        title: String,
    },
    /// Window row: label plus preformatted detail ("82% · resets in 4h").
    WindowRow {
        label: String,
        detail: String,
    },
    /// Plain, non-interactive text row (e.g. "Loading usage…").
    Text {
        text: String,
    },
    Separator,
    Action {
        title: String,
        action: StatusMenuAction,
        is_enabled: bool,
    },
}

/// A complete tray menu, renderable by any platform.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusMenuModel {
    pub entries: Vec<StatusMenuEntry>,
}

impl StatusMenuModel {
    pub fn new(entries: Vec<StatusMenuEntry>) -> Self {
        Self { entries }
    }
}

/// An extra per-provider tray widget.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct StatusWidgetModel {
    pub provider: String,
    pub title: String,
    pub menu: StatusMenuModel,
}

/// Builds tray models from usage + updater state.
pub struct StatusMenuBuilder;

impl StatusMenuBuilder {
    /// `includes_charts` is macOS-off / Linux+Windows-on: the macOS build has
    /// the dashboard already, so a separate Charts window would be a duplicate.
    /// `now` is seconds since the Unix epoch.
    pub fn main_menu(
        usage: &[ProviderUsage],
        update_version: Option<&str>,
        is_busy: bool,
        includes_charts: bool,
        now: i64,
    ) -> StatusMenuModel {
        let mut entries: Vec<StatusMenuEntry> = Vec::new();

        for provider in usage {
            let title = match &provider.plan {
                Some(plan) => format!("{} - {plan}", provider.provider_name),
                None => provider.provider_name.clone(),
            };
            entries.push(StatusMenuEntry::ProviderHeader { title });
            for window in &provider.windows {
                entries.push(StatusMenuEntry::WindowRow {
                    label: window.label.clone(),
                    detail: Self::detail(window, now),
                });
            }
            entries.push(StatusMenuEntry::Separator);
        }
        if usage.is_empty() {
            entries.push(StatusMenuEntry::Text {
                text: "Loading usage…".into(),
            });
            entries.push(StatusMenuEntry::Separator);
        }

        entries.push(StatusMenuEntry::Action {
            title: "Usage Dashboard…".into(),
            action: StatusMenuAction::OpenDashboard,
            is_enabled: true,
        });
        if includes_charts {
            entries.push(StatusMenuEntry::Action {
                title: "Charts…".into(),
                action: StatusMenuAction::OpenCharts,
                is_enabled: true,
            });
        }
        match update_version {
            Some(version) => entries.push(StatusMenuEntry::Action {
                title: format!("Update to {version}…"),
                action: StatusMenuAction::InstallUpdate {
                    version: version.to_string(),
                },
                is_enabled: !is_busy,
            }),
            None => entries.push(StatusMenuEntry::Action {
                title: "Check for Updates…".into(),
                action: StatusMenuAction::CheckForUpdates,
                is_enabled: !is_busy,
            }),
        }
        entries.push(StatusMenuEntry::Action {
            title: "Settings…".into(),
            action: StatusMenuAction::OpenSettings,
            is_enabled: true,
        });
        entries.push(StatusMenuEntry::Action {
            title: "Quit".into(),
            action: StatusMenuAction::Quit,
            is_enabled: true,
        });

        StatusMenuModel::new(entries)
    }

    /// Widget for a provider; a provider with no usage still yields a menu so
    /// the item isn't unresponsive.
    pub fn widget(provider: &str, usage: Option<&ProviderUsage>, now: i64) -> StatusWidgetModel {
        let mut entries: Vec<StatusMenuEntry> = Vec::new();
        for window in usage.map(|u| u.windows.as_slice()).unwrap_or(&[]) {
            entries.push(StatusMenuEntry::WindowRow {
                label: window.label.clone(),
                detail: Self::detail(window, now),
            });
        }
        entries.push(StatusMenuEntry::Separator);
        entries.push(StatusMenuEntry::Action {
            title: "Remove widget".into(),
            action: StatusMenuAction::RemoveWidget {
                provider: provider.to_string(),
            },
            is_enabled: true,
        });
        StatusWidgetModel {
            provider: provider.to_string(),
            title: Self::widget_title(provider, usage),
            menu: StatusMenuModel::new(entries),
        }
    }

    /// Widget button text: Monthly % when present, else the first window's.
    pub fn widget_title(provider: &str, usage: Option<&ProviderUsage>) -> String {
        let percent = usage
            .and_then(|u| u.window("Monthly").and_then(|w| w.percent_remaining))
            .or_else(|| usage.and_then(|u| u.windows.first().and_then(|w| w.percent_remaining)));
        match percent {
            Some(percent) => format!("{provider} {:.0}%", percent),
            None => format!("{provider} --"),
        }
    }

    /// Lowest Rolling remaining across providers, for the icon severity.
    pub fn worst_rolling_remaining(usage: &[ProviderUsage]) -> Option<f64> {
        usage
            .iter()
            .filter_map(|u| u.window("Rolling").and_then(|w| w.percent_remaining))
            .fold(None, |worst: Option<f64>, value| match worst {
                Some(current) if current <= value => Some(current),
                _ => Some(value),
            })
    }

    fn detail(window: &UsageWindow, now: i64) -> String {
        let percent = match window.percent_remaining {
            Some(percent) => format!("{percent:.0}"),
            None => "--".to_string(),
        };
        let mut detail = format!("{percent}%");
        if let Some(resets_at) = window.resets_at {
            detail.push_str(&format!(
                " · resets {}",
                RelativeTime::format(resets_at, now)
            ));
        }
        detail
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::UsageWindow;

    const NOW: i64 = 1_700_000_000;

    fn provider(name: &str, plan: Option<&str>, windows: Vec<UsageWindow>) -> ProviderUsage {
        ProviderUsage::new(name, plan.map(str::to_string), windows)
    }

    fn window(label: &str, percent: Option<f64>) -> UsageWindow {
        UsageWindow::new(label, 0, percent, None)
    }

    fn action_titles(model: &StatusMenuModel) -> Vec<&str> {
        model
            .entries
            .iter()
            .filter_map(|entry| match entry {
                StatusMenuEntry::Action { title, .. } => Some(title.as_str()),
                _ => None,
            })
            .collect()
    }

    /// `mainMenuListsProvidersWindowsAndActions` — provider header, one row per
    /// window, then the trailing actions.
    #[test]
    fn main_menu_lists_providers_windows_and_actions() {
        let usage = vec![provider(
            "Claude",
            Some("Team 5x"),
            vec![window("5-hour", Some(82.0)), window("Weekly", Some(64.0))],
        )];
        let model = StatusMenuBuilder::main_menu(&usage, None, false, false, NOW);

        assert_eq!(
            model.entries[0],
            StatusMenuEntry::ProviderHeader {
                title: "Claude - Team 5x".into()
            }
        );
        assert_eq!(
            model.entries[1],
            StatusMenuEntry::WindowRow {
                label: "5-hour".into(),
                detail: "82%".into()
            }
        );
        assert_eq!(
            model.entries[2],
            StatusMenuEntry::WindowRow {
                label: "Weekly".into(),
                detail: "64%".into()
            }
        );
        assert_eq!(model.entries[3], StatusMenuEntry::Separator);

        assert_eq!(
            action_titles(&model),
            vec![
                "Usage Dashboard…",
                "Check for Updates…",
                "Settings…",
                "Quit"
            ]
        );
    }

    /// `chartsRowIsOptIn` — no Charts row by default; Linux/Windows opt in.
    #[test]
    fn charts_row_is_opt_in() {
        let usage = vec![provider("Codex", None, vec![window("Rolling", Some(50.0))])];
        let without = StatusMenuBuilder::main_menu(&usage, None, false, false, NOW);
        assert!(!action_titles(&without).contains(&"Charts…"));

        let with = StatusMenuBuilder::main_menu(&usage, None, false, true, NOW);
        assert!(action_titles(&with).contains(&"Charts…"));
    }

    /// Empty usage shows the loading row rather than an empty menu.
    #[test]
    fn empty_usage_shows_loading_row() {
        let model = StatusMenuBuilder::main_menu(&[], None, false, false, NOW);
        assert_eq!(
            model.entries[0],
            StatusMenuEntry::Text {
                text: "Loading usage…".into()
            }
        );
        assert!(action_titles(&model).contains(&"Quit"));
    }

    /// A pending update replaces the check row and is disabled while busy.
    #[test]
    fn update_row_replaces_check_and_disables_while_busy() {
        let usage = vec![provider("Codex", None, vec![])];
        let offered = StatusMenuBuilder::main_menu(&usage, Some("0.9.0"), false, false, NOW);
        let titles = action_titles(&offered);
        assert!(titles.contains(&"Update to 0.9.0…"));
        assert!(!titles.contains(&"Check for Updates…"));
        let enabled = offered.entries.iter().any(|entry| {
            matches!(
                entry,
                StatusMenuEntry::Action {
                    action: StatusMenuAction::InstallUpdate { .. },
                    is_enabled: true,
                    ..
                }
            )
        });
        assert!(enabled);

        let busy = StatusMenuBuilder::main_menu(&usage, Some("0.9.0"), true, false, NOW);
        let disabled = busy.entries.iter().any(|entry| {
            matches!(
                entry,
                StatusMenuEntry::Action {
                    action: StatusMenuAction::InstallUpdate { .. },
                    is_enabled: false,
                    ..
                }
            )
        });
        assert!(disabled);
    }

    /// `widgetMenuEndsWithRemoveAction` — the remove row is always last.
    #[test]
    fn widget_menu_ends_with_remove_action() {
        let usage = provider("Claude", None, vec![window("Rolling", Some(70.0))]);
        let widget = StatusMenuBuilder::widget("Claude", Some(&usage), NOW);
        let last = widget.menu.entries.last().unwrap();
        assert_eq!(
            last,
            &StatusMenuEntry::Action {
                title: "Remove widget".into(),
                action: StatusMenuAction::RemoveWidget {
                    provider: "Claude".into()
                },
                is_enabled: true,
            }
        );
    }

    /// A widget with no usage still gets a responsive menu.
    #[test]
    fn widget_without_usage_still_has_menu() {
        let widget = StatusMenuBuilder::widget("Codex", None, NOW);
        assert_eq!(widget.title, "Codex --");
        assert_eq!(
            action_titles(&widget.menu),
            vec!["Remove widget"],
            "no window rows, but the remove action survives"
        );
    }

    /// `widgetTitlePrefersMonthlyThenFirstWindow` — Monthly wins, else the first.
    #[test]
    fn widget_title_prefers_monthly_then_first_window() {
        let both = provider(
            "Claude",
            None,
            vec![window("Rolling", Some(80.0)), window("Monthly", Some(12.0))],
        );
        assert_eq!(
            StatusMenuBuilder::widget_title("Claude", Some(&both)),
            "Claude 12%"
        );

        let first_only = provider("Claude", None, vec![window("Rolling", Some(80.0))]);
        assert_eq!(
            StatusMenuBuilder::widget_title("Claude", Some(&first_only)),
            "Claude 80%"
        );

        // A Monthly row with no percentage falls back to the first window.
        let monthly_none = provider(
            "Claude",
            None,
            vec![window("Rolling", Some(80.0)), window("Monthly", None)],
        );
        assert_eq!(
            StatusMenuBuilder::widget_title("Claude", Some(&monthly_none)),
            "Claude 80%"
        );
    }

    /// `worstRollingRemainingIsMinimumAcrossProviders` — drives icon severity.
    #[test]
    fn worst_rolling_remaining_is_minimum_across_providers() {
        let usage = vec![
            provider("Claude", None, vec![window("Rolling", Some(60.0))]),
            provider("Codex", None, vec![window("Rolling", Some(25.0))]),
            provider("Go", None, vec![window("Weekly", Some(5.0))]),
        ];
        assert_eq!(
            StatusMenuBuilder::worst_rolling_remaining(&usage),
            Some(25.0)
        );
        // Providers without a Rolling row are ignored.
        assert_eq!(StatusMenuBuilder::worst_rolling_remaining(&[]), None);
    }

    /// The detail row appends the reset countdown when the provider knows it.
    #[test]
    fn window_detail_includes_reset_time() {
        let window = UsageWindow::new("Weekly", 0, Some(40.0), Some(NOW + 2 * 3600));
        let usage = vec![provider("Codex", None, vec![window])];
        let model = StatusMenuBuilder::main_menu(&usage, None, false, false, NOW);
        match &model.entries[1] {
            StatusMenuEntry::WindowRow { detail, .. } => {
                assert_eq!(detail, "40% · resets in 2h")
            }
            other => panic!("expected a window row, got {other:?}"),
        }
    }

    /// Unknown percent renders as "--%", matching the Swift menu.
    #[test]
    fn missing_percent_shows_dash() {
        let usage = vec![provider("Codex", None, vec![window("Rolling", None)])];
        let model = StatusMenuBuilder::main_menu(&usage, None, false, false, NOW);
        match &model.entries[1] {
            StatusMenuEntry::WindowRow { detail, .. } => assert_eq!(detail, "--%"),
            other => panic!("expected a window row, got {other:?}"),
        }
    }
}
