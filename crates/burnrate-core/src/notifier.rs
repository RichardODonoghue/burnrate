//! Notification decisions: milestones, window resets, burn rate and daily spend.
//!
//! Ported 1:1 from `Sources/BurnRateCore/MilestoneNotifier.swift` plus the
//! evaluators in `Alerts.swift`.
//!
//! The evaluators are pure; this is the stateful part — remembering the last
//! reading per window so a crossing can be detected, and holding the cooldowns
//! that stop a notification repeating. The two subtleties, both from the Swift
//! build:
//!   - a **plan switch** must not fire a burst of milestones, so the history is
//!     reset when the account fingerprint changes;
//!   - a crossing while the reading was suppressed must not fire a notification
//!     the moment the rule is re-armed.

use std::collections::HashMap;
use std::time::Duration;

use serde::Serialize;

use crate::alerts::BurnAlert;
use crate::model::{ProviderUsage, UsageWindow};
use crate::settings::Settings;

/// One notification to deliver.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Notification {
    pub title: String,
    pub body: String,
    /// The rule that produced it, for logging and for the tests.
    #[serde(rename = "kind")]
    pub kind: &'static str,
}

/// Per-window state the notifier needs between polls.
#[derive(Debug, Default, Clone)]
struct WindowState {
    /// Last remaining % seen, i.e. the "previous" for a crossing test.
    last_remaining: Option<f64>,
    /// Monotonic second at which a burn alert last fired for this window.
    last_burn_fired: Option<i64>,
    /// Remaining-% history for the burn-rate baseline.
    history: Vec<crate::alerts::Reading>,
}

/// Decides which notifications to raise, given successive polls.
pub struct MilestoneNotifier {
    /// key "provider|window" -> state
    windows: HashMap<String, WindowState>,
    /// Days already alerted, so a daily cost cap fires once per day.
    cost_alerted_days: HashMap<String, i64>,
    /// Last plan/account fingerprint, used to detect a switch.
    account_fingerprint: Option<String>,
    /// Rules the user has switched on but which have not yet been armed.
    suppressed: HashMap<String, bool>,
    burn_cooldown: Duration,
}

impl Default for MilestoneNotifier {
    fn default() -> Self {
        Self::new()
    }
}

impl MilestoneNotifier {
    /// Poll interval used for the burn baseline slack, and the cooldown.
    pub fn new() -> Self {
        Self {
            windows: HashMap::new(),
            cost_alerted_days: HashMap::new(),
            account_fingerprint: None,
            suppressed: HashMap::new(),
            burn_cooldown: Duration::from_secs(30 * 60),
        }
    }

    pub fn with_burn_cooldown(mut self, cooldown: Duration) -> Self {
        self.burn_cooldown = cooldown;
        self
    }

    /// A plan switch (or a first poll) resets the per-window history, so a
    /// fresh account's 5% remaining does not read as "crossed 90, 80, 70…".
    pub fn set_account_fingerprint(&mut self, fingerprint: Option<String>) {
        if self.account_fingerprint != fingerprint {
            self.account_fingerprint = fingerprint;
            self.windows.clear();
        }
    }

    /// Marks a rule as armed or suppressed. While suppressed, crossings are
    /// recorded but not notified — so turning the rule back on does not
    /// immediately fire for everything crossed while it was off.
    pub fn set_rule_suppressed(&mut self, key: &str, suppressed: bool) {
        self.suppressed.insert(key.to_string(), suppressed);
    }

    /// Evaluates one poll. `now` is seconds since the Unix epoch;
    /// `poll_interval` is the poll cadence, used for the burn baseline slack.
    pub fn evaluate(
        &mut self,
        usage: &[ProviderUsage],
        settings: &Settings,
        now: i64,
        poll_interval: i64,
    ) -> Vec<Notification> {
        let mut notifications = Vec::new();
        let seen: Vec<String> = usage
            .iter()
            .flat_map(|provider| {
                provider
                    .windows
                    .iter()
                    .map(move |window| format!("{}|{}", provider.provider_name, window.label))
            })
            .collect();

        for provider in usage {
            for window in &provider.windows {
                let key = format!("{}|{}", provider.provider_name, window.label);
                let state = self.windows.entry(key.clone()).or_default();
                let previous = state.last_remaining;
                let current = window.percent_remaining;

                if let Some(current) = current {
                    state.history.push(crate::alerts::Reading {
                        date: now,
                        remaining: current,
                    });
                    // 6h retention: the longest window any rule can look back.
                    let cutoff = now - 6 * 3600;
                    state.history.retain(|reading| reading.date >= cutoff);
                }

                let suppressed = self.suppressed.get(&key).copied().unwrap_or(false);
                if !suppressed {
                    if let (Some(previous), Some(current)) = (previous, current) {
                        for milestone in &settings.milestones {
                            if milestone.provider != provider.provider_name
                                || milestone.window_label != window.label
                            {
                                continue;
                            }
                            if let Some(level) =
                                crate::alerts::MilestoneEvaluator::crossed_threshold(
                                    Some(previous),
                                    current,
                                    milestone.step,
                                )
                            {
                                notifications.push(milestone_notification(provider, window, level));
                            }
                        }

                        if settings.notify_on_reset {
                            // Remaining jumping back up is a reset.
                            if current > previous + 5.0 {
                                notifications.push(Notification {
                                    title: format!(
                                        "{} {} reset",
                                        provider.provider_name, window.label
                                    ),
                                    body: format!("Back to {current:.0}% remaining."),
                                    kind: "reset",
                                });
                            }
                        }

                        for alert in &settings.burn_alerts {
                            if alert.provider != provider.provider_name
                                || alert.window_label != window.label
                            {
                                continue;
                            }
                            let cooldown = self.burn_cooldown.as_secs() as i64;
                            if let Some(fired) =
                                evaluate_burn(alert, state, now, poll_interval, cooldown)
                            {
                                state.last_burn_fired = Some(now);
                                notifications.push(fired);
                            }
                        }
                    }
                }

                state.last_remaining = current;
            }
        }

        // Forget windows that no longer exist (a provider was removed).
        self.windows
            .retain(|key, _| seen.iter().any(|seen_key| seen_key == key));
        notifications
    }

    /// Daily spend check. OpenCode is the only source that reports cost, so
    /// this only fires when the caller has cost data.
    pub fn evaluate_cost(
        &mut self,
        today_start: i64,
        spend_by_provider: &HashMap<String, f64>,
        settings: &Settings,
        now: i64,
    ) -> Vec<Notification> {
        let mut notifications = Vec::new();
        for alert in &settings.cost_alerts {
            let Some(spent) = spend_by_provider.get(&alert.provider) else {
                continue;
            };
            let day = now / 86_400;
            if *spent < alert.daily_limit_usd {
                // Under the cap again: allow it to fire again another day.
                self.cost_alerted_days.remove(&alert.provider);
                continue;
            }
            if self.cost_alerted_days.get(&alert.provider) == Some(&day) {
                continue; // once per day
            }
            self.cost_alerted_days.insert(alert.provider.clone(), day);
            notifications.push(Notification {
                title: format!("{} spend", alert.provider),
                body: format!(
                    "${:.2} today, over the ${:.0} cap.",
                    spent, alert.daily_limit_usd
                ),
                kind: "cost",
            });
        }
        let _ = today_start;
        notifications
    }
}

/// One burn-rate notification, or `None` when there is nothing to report.
fn evaluate_burn(
    alert: &BurnAlert,
    state: &mut WindowState,
    now: i64,
    poll_interval: i64,
    cooldown: i64,
) -> Option<Notification> {
    let detection =
        crate::alerts::BurnRateEvaluator::detect(&state.history, alert, now, poll_interval)?;
    if let Some(last) = state.last_burn_fired {
        if now - last < cooldown {
            return None;
        }
    }
    Some(Notification {
        title: format!("{} burning fast", alert.provider),
        body: format!(
            "{:.0}% remaining, down {:.0} points in {} min.",
            detection.current, detection.drop, alert.minutes
        ),
        kind: "burn",
    })
}

fn milestone_notification(
    provider: &ProviderUsage,
    window: &UsageWindow,
    level: f64,
) -> Notification {
    Notification {
        title: format!("{} at {:.0}%", provider.provider_name, level),
        body: format!(
            "{} is down to {:.0}% remaining.",
            window.label,
            window.percent_remaining.unwrap_or(0.0)
        ),
        kind: "milestone",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::alerts::{CostAlert, Milestone};

    const NOW: i64 = 1_700_000_000;

    fn provider(name: &str, window_label: &str, percent: f64) -> ProviderUsage {
        ProviderUsage::new(
            name,
            None,
            vec![UsageWindow::new(window_label, 0, Some(percent), None)],
        )
    }

    fn settings_for(step: f64) -> Settings {
        Settings {
            milestones: vec![Milestone::new("Claude", "Rolling", step)],
            burn_alerts: Vec::new(),
            cost_alerts: Vec::new(),
            notify_on_reset: false,
            ..Settings::default()
        }
    }

    /// `crossesDownPastLevel` through the notifier: 95% → 55% with step 20
    /// reports the highest level crossed, once.
    #[test]
    fn milestone_fires_once_per_crossing() {
        let mut notifier = MilestoneNotifier::new();
        let settings = settings_for(20.0);
        assert!(
            notifier
                .evaluate(&[provider("Claude", "Rolling", 95.0)], &settings, NOW, 300)
                .is_empty(),
            "first observation never fires"
        );
        let fired = notifier.evaluate(
            &[provider("Claude", "Rolling", 55.0)],
            &settings,
            NOW + 300,
            300,
        );
        assert_eq!(fired.len(), 1, "reports one notification, not three");
        assert_eq!(fired[0].kind, "milestone");
        assert!(fired[0].title.contains("80"), "got {}", fired[0].title);
    }

    /// Staying above the level does not re-fire.
    #[test]
    fn no_repeat_while_still_below_level() {
        let mut notifier = MilestoneNotifier::new();
        let settings = settings_for(20.0);
        notifier.evaluate(&[provider("Claude", "Rolling", 95.0)], &settings, NOW, 300);
        notifier.evaluate(
            &[provider("Claude", "Rolling", 55.0)],
            &settings,
            NOW + 300,
            300,
        );
        let again = notifier.evaluate(
            &[provider("Claude", "Rolling", 54.0)],
            &settings,
            NOW + 600,
            300,
        );
        assert!(again.is_empty(), "55 → 54 crosses nothing new");
    }

    /// A suppressed rule records the crossing but does not notify, and does not
    /// fire retroactively when re-armed.
    #[test]
    fn suppressed_rule_does_not_fire_when_rearmed() {
        let mut notifier = MilestoneNotifier::new();
        let settings = settings_for(20.0);
        notifier.set_rule_suppressed("Claude|Rolling", true);
        notifier.evaluate(&[provider("Claude", "Rolling", 95.0)], &settings, NOW, 300);
        assert!(notifier
            .evaluate(
                &[provider("Claude", "Rolling", 55.0)],
                &settings,
                NOW + 300,
                300
            )
            .is_empty());

        notifier.set_rule_suppressed("Claude|Rolling", false);
        let after = notifier.evaluate(
            &[provider("Claude", "Rolling", 54.0)],
            &settings,
            NOW + 600,
            300,
        );
        assert!(
            after.is_empty(),
            "the missed crossing is not delivered late"
        );
    }

    /// `accountSwitchSuppressesPhantomResetAndMilestones` — a new plan starts
    /// clean.
    #[test]
    fn account_switch_suppresses_a_burst() {
        let mut notifier = MilestoneNotifier::new();
        let settings = settings_for(20.0);
        notifier.set_account_fingerprint(Some("acct-a".into()));
        notifier.evaluate(&[provider("Claude", "Rolling", 95.0)], &settings, NOW, 300);

        // Switch accounts; the new plan is already at 5%.
        notifier.set_account_fingerprint(Some("acct-b".into()));
        let burst = notifier.evaluate(
            &[provider("Claude", "Rolling", 5.0)],
            &settings,
            NOW + 300,
            300,
        );
        assert!(burst.is_empty(), "no phantom milestones after a switch");
    }

    /// `resetWithoutAccountSwitchStillAlerts` — a genuine reset still notifies.
    #[test]
    fn window_reset_notifies() {
        let mut notifier = MilestoneNotifier::new();
        let mut settings = settings_for(20.0);
        settings.notify_on_reset = true;
        notifier.evaluate(&[provider("Claude", "Rolling", 10.0)], &settings, NOW, 300);
        let reset = notifier.evaluate(
            &[provider("Claude", "Rolling", 98.0)],
            &settings,
            NOW + 300,
            300,
        );
        assert_eq!(reset.len(), 1);
        assert_eq!(reset[0].kind, "reset");
    }

    /// `accountSwitchSuppressesPhantomResetAndMilestones` also covers a reset
    /// that is really a plan change: 5% on the old plan, then the new plan
    /// starts high.
    #[test]
    fn plan_change_does_not_look_like_a_reset() {
        let mut notifier = MilestoneNotifier::new();
        let mut settings = settings_for(20.0);
        settings.notify_on_reset = true;
        notifier.set_account_fingerprint(Some("acct-a".into()));
        notifier.evaluate(&[provider("Claude", "Rolling", 5.0)], &settings, NOW, 300);
        notifier.set_account_fingerprint(Some("acct-b".into()));
        let after = notifier.evaluate(
            &[provider("Claude", "Rolling", 100.0)],
            &settings,
            NOW + 300,
            300,
        );
        assert!(after.is_empty());
    }

    /// `firesOnFastDrop` through the notifier, including the cooldown.
    ///
    /// The rule needs a baseline at least `minutes` old, so this walks six
    /// 5-minute polls — a 30-minute window that a 15-minute test would
    /// (correctly) refuse to judge.
    #[test]
    fn burn_alert_fires_once_then_cools_down() {
        let mut notifier = MilestoneNotifier::new().with_burn_cooldown(Duration::from_secs(1800));
        let settings = Settings {
            milestones: Vec::new(),
            burn_alerts: vec![BurnAlert::new("Claude", "Rolling", 15.0, 30)],
            cost_alerts: Vec::new(),
            notify_on_reset: false,
            ..Settings::default()
        };
        let mut fired_any = Vec::new();
        for step in 0..=6 {
            let percent = 80.0 - 4.0 * step as f64;
            let at = NOW + 300 * step;
            let fired = notifier.evaluate(
                &[provider("Claude", "Rolling", percent)],
                &settings,
                at,
                300,
            );
            // Nothing before the window has spanned 30 minutes.
            if step < 5 {
                assert!(fired.is_empty(), "fired early at step {step}: {fired:?}");
            }
            fired_any.push((step, fired));
        }
        let first_fire = fired_any
            .iter()
            .find(|(_, fired)| !fired.is_empty())
            .expect("burn alert never fired");
        // The baseline is the oldest reading in the trailing window, and it must
        // be at least `minutes` old minus half a poll of slack — so with a
        // 5-minute cadence the first eligible poll is 30 minutes in (step 6).
        assert_eq!(first_fire.0, 6, "fires once the window spans 30 min");
        assert_eq!(first_fire.1[0].kind, "burn");
        assert!(
            first_fire.1[0].body.contains("down 24 points"),
            "got {}",
            first_fire.1[0].body
        );

        // A further poll inside the cooldown does not fire again.
        let mut after = notifier.evaluate(
            &[provider("Claude", "Rolling", 50.0)],
            &settings,
            NOW + 300 * 7,
            300,
        );
        assert!(after.is_empty(), "cooldown holds right after firing");
        after = notifier.evaluate(
            &[provider("Claude", "Rolling", 30.0)],
            &settings,
            NOW + 300 * 13,
            300,
        );
        assert_eq!(after.len(), 1, "fires again once the cooldown expires");
        assert_eq!(after[0].kind, "burn");
    }

    /// Cost alerts fire once per day and re-arm below the cap.
    #[test]
    fn cost_alert_fires_once_per_day() {
        let mut notifier = MilestoneNotifier::new();
        let settings = Settings {
            cost_alerts: vec![CostAlert::new("OpenCode Go", 20.0)],
            ..Settings::default()
        };
        let spend = HashMap::from([("OpenCode Go".to_string(), 25.0)]);
        let day = NOW / 86_400;
        let first = notifier.evaluate_cost(day * 86_400, &spend, &settings, NOW);
        assert_eq!(first.len(), 1);
        assert_eq!(first[0].kind, "cost");
        // Same day again: nothing.
        assert!(notifier
            .evaluate_cost(day * 86_400, &spend, &settings, NOW + 60)
            .is_empty());
        // Next day: fires again.
        let tomorrow = notifier.evaluate_cost(
            (day + 1) * 86_400,
            &spend,
            &settings,
            (day + 1) * 86_400 + 10,
        );
        assert_eq!(tomorrow.len(), 1);
    }

    #[test]
    fn cost_under_the_cap_does_not_notify() {
        let mut notifier = MilestoneNotifier::new();
        let settings = Settings {
            cost_alerts: vec![CostAlert::new("OpenCode Go", 20.0)],
            ..Settings::default()
        };
        let spend = HashMap::from([("OpenCode Go".to_string(), 3.0)]);
        assert!(notifier.evaluate_cost(0, &spend, &settings, NOW).is_empty());
    }

    /// A window that disappears stops being tracked, so a re-added provider
    /// starts from a clean comparison rather than a stale "previous".
    #[test]
    fn vanished_windows_are_forgotten() {
        let mut notifier = MilestoneNotifier::new();
        let settings = settings_for(20.0);
        notifier.evaluate(&[provider("Claude", "Rolling", 95.0)], &settings, NOW, 300);
        notifier.evaluate(&[], &settings, NOW + 300, 300);
        // Back again at 55%: treated as a first observation, so no milestone.
        let back = notifier.evaluate(
            &[provider("Claude", "Rolling", 55.0)],
            &settings,
            NOW + 600,
            300,
        );
        assert!(back.is_empty());
    }
}
