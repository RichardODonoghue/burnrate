# Parity checklist — Swift `BurnRateCore` → Rust `burnrate-core`

Source of truth: `Tests/BurnRateCoreTests` on `main` (111 tests). Each line is
one Swift `@Test`; the Rust side gets a `#[test]` with the same name and the
same behaviour. Port faithfully — if a test looks wrong, fix it in a separate
change after parity, never while porting.

Status: **92 / 112 ported.** `burnrate-core` now holds the usage model, formatting,
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

- [ ] `noWindowsNeverDue`
- [ ] `futureResetNotDue`
- [ ] `resetPassedAfterLastFetchIsDue`
- [ ] `fetchedSinceResetNotDue`
- [ ] `missingResetsAtNeverDue`
- [ ] `anyDueWindowForcesRefresh`
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

- [ ] `cutoffIsTrailingWindow`
- [ ] `tickStyleFollowsVisibleSpanNotSelectedRange`
- [ ] `hourlyStrideWidensWithSpan`
- [x] `xDomainShrinksToAvailableData`
- [x] `xDomainFallsBackToFullRangeWhenEmpty`
- [ ] `tickDatesAreMidnightsAndNoonsInSpan`
- [ ] `tooltipPicksNearestPointPerSeries`
- [x] `nearestPointBinarySearchesSortedSamples`
- [ ] `todayRangeDropsOlderPoints`
- [ ] `weekRangeKeepsDaysButDropsOlderWeeks`
- [ ] `allOutOfRangeYieldsNoSeries`
- [x] `scopedWeeklyFoldsIntoWeeklyGraph`
- [x] `providerFilterAppliesWithinRange`
- [x] `emptySeriesUsesFullDomain`
- [ ] `narrowRangePadsAndTightensDomain`
- [ ] `domainClampsTo0And100`
- [ ] `flatSeriesGetsAWindow`
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
- [ ] `claudeAccountFingerprintUsesAccountAndOrg`
- [ ] `tokenHashFallbackDiffersPerToken`

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

## Still open (20)

Grouped, because the raw list does not say which are one feature:

- **Window-reset alerting (7)** — `noWindowsNeverDue`, `futureResetNotDue`,
  `resetPassedAfterLastFetchIsDue`, `fetchedSinceResetNotDue`,
  `missingResetsAtNeverDue`, `anyDueWindowForcesRefresh`, `cutoffIsTrailingWindow`.
  The Swift build has a reset-notification path distinct from the milestone
  path; this port currently notifies on a jump in remaining, not on a reset
  deadline. Not equivalent yet.
- **Chart axis/tick domain (7)** — `tickStyleFollowsVisibleSpanNotSelectedRange`,
  `hourlyStrideWidensWithSpan`, `tickDatesAreMidnightsAndNoonsInSpan`,
  `todayRangeDropsOlderPoints`, `weekRangeKeepsDaysButDropsOlderWeeks`,
  `allOutOfRangeYieldsNoSeries`, `narrowRangePadsAndTightensDomain`,
  `domainClampsTo0And100`, `flatSeriesGetsAWindow`. The series exist and draw;
  the Swift build's tick *style* rules do not.
- **Chart tooltip picking (1)** — `tooltipPicksNearestPointPerSeries`. The Rust
  `nearest_point` exists and is tested; the Swift test additionally asserts
  per-series picking, which the frontend does in a loop.
- **Claude account fingerprint (2)** — `claudeAccountFingerprintUsesAccountAndOrg`,
  `tokenHashFallbackDiffersPerToken`. The notifier resets on fingerprint change,
  but nothing produces a fingerprint yet, so a plan switch is not detected.
- **`rusqlite`** — a checklist line, not a test: the bundled-SQLite swap is done
  and covered by `sqlite_queries_return_tab_separated_rows`.

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

- [ ] Menu structure matches `StatusMenuBuilder` (`mainMenu`, `widgetMenu`,
      `chartsRowIsOptIn` → `Charts…` only on Linux/Windows)
- [ ] Icon spec/severity stops match `StatusIcon`
- [ ] Relative-time formatting matches `RelativeTime`
- [ ] Per-OS credential paths match `AppPaths` (`dataDirectory`/`configDirectory`
      honouring XDG; macOS Keychain via `security`)
- [ ] `rusqlite` (bundled, read-only) replaces shelling out to `/usr/bin/sqlite3`
- [ ] Provider diagnostics (`lastStatus`) surfaced in the UI