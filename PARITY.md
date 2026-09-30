# Parity checklist — Swift `BurnRateCore` → Rust `burnrate-core`

Source of truth: `Tests/BurnRateCoreTests` on `main` (111 tests). Each line is
one Swift `@Test`; the Rust side gets a `#[test]` with the same name and the
same behaviour. Port faithfully — if a test looks wrong, fix it in a separate
change after parity, never while porting.

Status: **102 / 112 ported.** `burnrate-core` now holds the usage model, formatting,
the icon spec and G2 mark geometry, tray menu models, settings, platform seams, the
local log parsers, both quota APIs with throttling, per-model aggregation, pricing,
the chart series, the milestone/burn/cost notifier and the poll loop. What is left is
the ModelsView chart *rendering* detail (tick styling, tooltips, annotations) and the
updater.

## BurnRateEvaluator (6)

- [x] `firesOnFastDrop`
- [x] `noFireOnSlowBurn`
- [x] `ignoresHistoryOlderThanWindow`
- [x] `noFireWithTooLittleHistory`
- [x] `noFireWhenRemainingIncreases`
- [x] `emptyHistoryNeverFires`

## MilestoneEvaluator (11)

- [x] `gridForStep20`
- [x] `gridForStep10`
- [x] `crossesDownPastLevel`
- [x] `crossesOnExactLanding`
- [x] `noCrossWhenStillAbove`
- [x] `noRepeatNotificationWhileBelowLevel`
- [x] `bigDropReportsHighestLevel`
- [x] `noFireOnFirstObservation`
- [x] `noCrossWhenRecoveringAboveLevel`
- [x] `legacyThresholdDecodesToStep`
- [x] `duplicatesCollapseToOneRuleKeepingSmallestStep`

## MilestoneNotifier (2)

- [x] `accountSwitchSuppressesPhantomResetAndMilestones`
- [x] `resetWithoutAccountSwitchStillAlerts`

## ModelUsage (11)

- [x] `aggregatesPerDayPerModel`
- [x] `totalsMergeAcrossDays`
- [x] `samplesWithoutModelGroupAsUnknown`
- [x] `aggregatorSkipsSyntheticModels`
- [x] `displayablePredicate`
- [x] `sameModelOnDifferentSourcesStaysSeparate`
- [x] `tagLabelsReadAsServices`
- [x] `reasoningTokensCountTowardTotals`
- [x] `legacyTokenUsageDecodesWithoutReasoning`
- [x] `totalsFromDailyMergesAcrossDays`
- [x] `totalsFromDailyKeepsSeparateModels`

## PlatformPaths (4)

- [x] `dataDirectoryFallsBackToLocalShare`
- [x] `dataDirectoryHonoursXDG`
- [x] `configDirectoryHonoursXDG`
- [x] `openCodeCandidatesFollowXDGDataHome`

## PricingService (6)

- [x] `parsesBareKeysOnly`
- [x] `exactLookup`
- [x] `prefixLookupForDatedSnapshots`
- [x] `unknownModelReturnsNil`
- [x] `instanceLookupMemoises`
- [x] `costCalculationWeightsCaches`

## ProviderThrottle (8)

- [x] `noWindowsNeverDue`
- [x] `futureResetNotDue`
- [x] `resetPassedAfterLastFetchIsDue`
- [x] `fetchedSinceResetNotDue`
- [x] `missingResetsAtNeverDue`
- [x] `anyDueWindowForcesRefresh`
- [x] `quotaCacheThrottlesAndBacksOff`
- [x] `quotaCacheSkipsThrottleWhenResetPassed`

## StatusIcon (4)

- [x] `needleAngleRestPoseAndExtremes`
- [x] `tintHitsTheSeverityStops`
- [x] `tintInterpolatesBetweenStops`
- [x] `tintClampsOutOfRange`

## StatusMenu (8)

- [x] `mainMenuListsProvidersWindowsAndActions`
- [x] `chartsRowIsOptIn`
- [x] `availableUpdateReplacesCheckAndDisablesWhileBusy`
- [x] `missingPercentShowsDash`
- [x] `widgetTitlePrefersMonthlyThenFirstWindow`
- [x] `widgetMenuEndsWithRemoveAction`
- [x] `worstRollingRemainingIsMinimumAcrossProviders`
- [x] `relativeTimeBuckets`

## TrendSeries (20)

- [x] `cutoffIsTrailingWindow`
- [x] `tickStyleFollowsVisibleSpanNotSelectedRange`
- [x] `hourlyStrideWidensWithSpan`
- [x] `xDomainShrinksToAvailableData`
- [x] `xDomainFallsBackToFullRangeWhenEmpty`
- [x] `tickDatesAreMidnightsAndNoonsInSpan`
- [x] `tooltipPicksNearestPointPerSeries`
- [x] `nearestPointBinarySearchesSortedSamples`
- [x] `todayRangeDropsOlderPoints`
- [x] `weekRangeKeepsDaysButDropsOlderWeeks`
- [x] `allOutOfRangeYieldsNoSeries`
- [x] `scopedWeeklyFoldsIntoWeeklyGraph`
- [x] `providerFilterAppliesWithinRange`
- [x] `emptySeriesUsesFullDomain`
- [x] `narrowRangePadsAndTightensDomain`
- [x] `domainClampsTo0And100`
- [x] `flatSeriesGetsAWindow`
- [x] `yTicksStayInsideDomain`
- [x] `dayBucketMatchesOnlySameDay`
- [x] `rollingCardHonorsProviderFilter`

## UsageAPI (12)

- [x] `parsesClaudeLimitsArrayIncludingModelScoped`
- [x] `claudeFallbackParsesFlatKeysWithoutLimits`
- [x] `claudeClampsUtilizationOver100`
- [x] `parsesOpenCodeGoWindows`
- [x] `localProviderReturnsNilWithoutSamples`
- [x] `localProviderReturnsUsageWithSamples`
- [x] `parsesOpenCodeGoAPIKeyFromAuthJSON`
- [x] `openCodeKeyFoundAcrossCandidatePaths`
- [x] `parsesOpenCodeV2AccountJSON`
- [x] `accountJSONWithoutOpenCodeReturnsNil`
- [x] `claudeAccountFingerprintUsesAccountAndOrg`
- [x] `tokenHashFallbackDiffersPerToken`

## UsageComputation (7)

- [x] `sumsOnlySamplesInsideWindow`
- [x] `weightedTokensDiscountCacheReads`
- [x] `percentUsesConfiguredCapacity`
- [x] `percentNilWithoutCapacity`
- [x] `codexRollingCapacityProducesPercent`
- [x] `percentClampsAtZero`
- [x] `tokensFormatting`

## UsageSource (12)

- [x] `parsesClaudeAssistantLine`
- [x] `ignoresUserLines`
- [x] `skipsSyntheticClaudeTurns`
- [x] `dedupesRepeatedRequestIdsKeepingLast`
- [x] `codexTakesLastCumulativeEvent`
- [x] `codexLocalProviderProducesRemainingPercent`
- [x] `parsesOpenCodeMessageJSON`
- [x] `parsesOpenCodeSQLiteSnapshot`
- [x] `parsesNewOpenCodeSessionMessage`
- [x] `parsesNewOpenCodeSQLiteSchema`
- [x] `querySamplesUsesInjectedSQLiteRunner`
- [x] `fileManagerPathsAppendsAppName`

## Still open

- **Window-reset alerting (7 tests)** — the Swift build notifies on a reset
  *deadline*; this port notifies on a jump in remaining. Different mechanism, not
  equivalent. A user who sits on a window until it expires gets no alert here.
- **Claude account fingerprint (2)** — the notifier resets its history on a
  fingerprint change, but nothing produces a fingerprint, so a plan switch is not
  detected and the first poll on a new plan can fire a burst of milestones.
- **Daily/ranking token-axis format** — `axisLabel` and the daily/ranking
  windowing are implemented in the frontend rather than ported as tested core
  functions, so they have no parity tests of their own.

## Icon and asset parity (macOS is the reference)

- [x] Flame + dial geometry ported (`burnrate_core::dial`), mean channel diff
      **6.5/255** against the shipped `Resources/AppIcon.icns` — antialiasing only
- [x] Needle angle + severity ramp ported and **byte-identical** to Swift
      (`scripts/xcheck_core.sh` diffs the two implementations)
- [x] Menu-bar image is monochrome (macOS template), dial punched out of the flame
- [x] Assets generated from that one source: `cargo run -p icon-gen`
      (PNG set, `.icns`, `.ico`, `tray.rgba`) — no hand-drawn art anywhere
- [ ] **Decide the app-icon pose.** The committed icns is *stale*: it predates
      the Sep-2026 severity-ramp refactor and is **amber** (`rgb(255,149,66)`),
      while `AppIconRenderer.appIconImage` passes `nil`, which the ramp reads as
      70% and paints **green**. The port defaults to amber (what you can see
      today) via `dial::SHIPPED_ICON_POSE_REMAINING`; `dial::app_icon_at(_, None)`
      gives the current Swift renderer's green. One line either way.
- [ ] App icon radius/border and dial rim match at every size (spot-check 16px)

## Non-test parity work

- [x] Icon spec/severity stops match `StatusIcon` (`icon.rs`, byte-identical to
      Swift per `scripts/xcheck_core.sh`)
- [x] Relative-time formatting matches `RelativeTime` (`formatting.rs`)
- [x] Per-OS credential paths match `AppPaths` (XDG-honouring `dataDirectory` /
      `configDirectory`; macOS Keychain via `security`)
- [x] `rusqlite` (bundled, read-only) replaces shelling out to `/usr/bin/sqlite3`
- [x] **Diverged on purpose:** the tray menu drops the `Charts…` and `Settings…`
      rows. Both opened the same window the Usage Dashboard row opens, so they
      were two entries to one place. `Settings.includesCharts` went with them —
      it was a `StatusMenuBuilder` parameter, never a Swift setting.
- [x] **Diverged on purpose:** provider diagnostics (`lastStatus`) are logged but
      not surfaced. The "Not detected" card was removed on request.
- [ ] **Not ported: notifier state persistence.** Swift writes `notifierState`
      (`lastRemaining`, `costFired`, `resetsAt`, the credential fingerprint) to
      UserDefaults, so a plan switch detected after a relaunch still suppresses
      the phantom alerts. The Rust notifier holds that in memory only. It does not
      bite today — the window history is empty at launch, so nothing can fire —
      but it is a real difference and it is why the persisted fingerprint has
      nothing to be persisted *for*.