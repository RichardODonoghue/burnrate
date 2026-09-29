# Parity checklist — Swift `BurnRateCore` → Rust `burnrate-core`

Source of truth: `Tests/BurnRateCoreTests` on `main` (111 tests). Each line is
one Swift `@Test`; the Rust side gets a `#[test]` with the same name and the
same behaviour. Port faithfully — if a test looks wrong, fix it in a separate
change after parity, never while porting.

Status: **36 / 112 ported.** `crates/burnrate-core` currently covers the usage
model, formatting, the icon spec + G2 mark geometry, the tray menu models and the
milestone/burn evaluators. Parsers, quota providers, chart series, per-model
aggregation and pricing are still to do.

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
- [ ] `noRepeatNotificationWhileBelowLevel`
- [ ] `bigDropReportsHighestLevel`
- [x] `noFireOnFirstObservation`
- [x] `noCrossWhenRecoveringAboveLevel`
- [ ] `legacyThresholdDecodesToStep`
- [x] `duplicatesCollapseToOneRuleKeepingSmallestStep`

## MilestoneNotifier (2)

- [ ] `accountSwitchSuppressesPhantomResetAndMilestones`
- [ ] `resetWithoutAccountSwitchStillAlerts`

## ModelUsage (11)

- [ ] `aggregatesPerDayPerModel`
- [ ] `totalsMergeAcrossDays`
- [ ] `samplesWithoutModelGroupAsUnknown`
- [ ] `aggregatorSkipsSyntheticModels`
- [ ] `displayablePredicate`
- [ ] `sameModelOnDifferentSourcesStaysSeparate`
- [ ] `tagLabelsReadAsServices`
- [x] `reasoningTokensCountTowardTotals`
- [x] `legacyTokenUsageDecodesWithoutReasoning`
- [ ] `totalsFromDailyMergesAcrossDays`
- [ ] `totalsFromDailyKeepsSeparateModels`

## PlatformPaths (4)

- [ ] `dataDirectoryFallsBackToLocalShare`
- [ ] `dataDirectoryHonoursXDG`
- [ ] `configDirectoryHonoursXDG`
- [ ] `openCodeCandidatesFollowXDGDataHome`

## PricingService (6)

- [ ] `parsesBareKeysOnly`
- [ ] `exactLookup`
- [ ] `prefixLookupForDatedSnapshots`
- [ ] `unknownModelReturnsNil`
- [ ] `instanceLookupMemoises`
- [ ] `costCalculationWeightsCaches`

## ProviderThrottle (8)

- [ ] `noWindowsNeverDue`
- [ ] `futureResetNotDue`
- [ ] `resetPassedAfterLastFetchIsDue`
- [ ] `fetchedSinceResetNotDue`
- [ ] `missingResetsAtNeverDue`
- [ ] `anyDueWindowForcesRefresh`
- [ ] `quotaCacheThrottlesAndBacksOff`
- [ ] `quotaCacheSkipsThrottleWhenResetPassed`

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
- [ ] `xDomainShrinksToAvailableData`
- [ ] `xDomainFallsBackToFullRangeWhenEmpty`
- [ ] `tickDatesAreMidnightsAndNoonsInSpan`
- [ ] `tooltipPicksNearestPointPerSeries`
- [ ] `nearestPointBinarySearchesSortedSamples`
- [ ] `todayRangeDropsOlderPoints`
- [ ] `weekRangeKeepsDaysButDropsOlderWeeks`
- [ ] `allOutOfRangeYieldsNoSeries`
- [ ] `scopedWeeklyFoldsIntoWeeklyGraph`
- [ ] `providerFilterAppliesWithinRange`
- [ ] `emptySeriesUsesFullDomain`
- [ ] `narrowRangePadsAndTightensDomain`
- [ ] `domainClampsTo0And100`
- [ ] `flatSeriesGetsAWindow`
- [ ] `yTicksStayInsideDomain`
- [ ] `dayBucketMatchesOnlySameDay`
- [ ] `rollingCardHonorsProviderFilter`

## UsageAPI (12)

- [ ] `parsesClaudeLimitsArrayIncludingModelScoped`
- [ ] `claudeFallbackParsesFlatKeysWithoutLimits`
- [ ] `claudeClampsUtilizationOver100`
- [ ] `parsesOpenCodeGoWindows`
- [ ] `localProviderReturnsNilWithoutSamples`
- [ ] `localProviderReturnsUsageWithSamples`
- [ ] `parsesOpenCodeGoAPIKeyFromAuthJSON`
- [ ] `openCodeKeyFoundAcrossCandidatePaths`
- [ ] `parsesOpenCodeV2AccountJSON`
- [ ] `accountJSONWithoutOpenCodeReturnsNil`
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

- [ ] `parsesClaudeAssistantLine`
- [ ] `ignoresUserLines`
- [ ] `skipsSyntheticClaudeTurns`
- [ ] `dedupesRepeatedRequestIdsKeepingLast`
- [ ] `codexTakesLastCumulativeEvent`
- [x] `codexLocalProviderProducesRemainingPercent`
- [ ] `parsesOpenCodeMessageJSON`
- [ ] `parsesOpenCodeSQLiteSnapshot`
- [ ] `parsesNewOpenCodeSessionMessage`
- [ ] `parsesNewOpenCodeSQLiteSchema`
- [ ] `querySamplesUsesInjectedSQLiteRunner`
- [ ] `fileManagerPathsAppendsAppName`

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
