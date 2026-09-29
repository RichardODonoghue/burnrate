# Parity checklist — Swift `BurnRateCore` → Rust `burnrate-core`

Source of truth: `Tests/BurnRateCoreTests` on `main` (111 tests). Each line is
one Swift `@Test`; the Rust side gets a `#[test]` with the same name and the
same behaviour. Port faithfully — if a test looks wrong, fix it in a separate
change after parity, never while porting.

Status: **0 / 111 ported.** `crates/burnrate-core` currently holds only
foundational tests (`format_remaining` percent formatting); everything below is
still to do.

## BurnRateEvaluator (6)

- [ ] `firesOnFastDrop`
- [ ] `noFireOnSlowBurn`
- [ ] `ignoresHistoryOlderThanWindow`
- [ ] `noFireWithTooLittleHistory`
- [ ] `noFireWhenRemainingIncreases`
- [ ] `emptyHistoryNeverFires`

## MilestoneEvaluator (11)

- [ ] `gridForStep20`
- [ ] `gridForStep10`
- [ ] `crossesDownPastLevel`
- [ ] `crossesOnExactLanding`
- [ ] `noCrossWhenStillAbove`
- [ ] `noRepeatNotificationWhileBelowLevel`
- [ ] `bigDropReportsHighestLevel`
- [ ] `noFireOnFirstObservation`
- [ ] `noCrossWhenRecoveringAboveLevel`
- [ ] `legacyThresholdDecodesToStep`
- [ ] `duplicatesCollapseToOneRuleKeepingSmallestStep`

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
- [ ] `reasoningTokensCountTowardTotals`
- [ ] `legacyTokenUsageDecodesWithoutReasoning`
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

- [ ] `needleAngleRestPoseAndExtremes`
- [ ] `tintHitsTheSeverityStops`
- [ ] `tintInterpolatesBetweenStops`
- [ ] `tintClampsOutOfRange`

## StatusMenu (8)

- [ ] `mainMenuListsProvidersWindowsAndActions`
- [ ] `chartsRowIsOptIn`
- [ ] `availableUpdateReplacesCheckAndDisablesWhileBusy`
- [ ] `missingPercentShowsDash`
- [ ] `widgetTitlePrefersMonthlyThenFirstWindow`
- [ ] `widgetMenuEndsWithRemoveAction`
- [ ] `worstRollingRemainingIsMinimumAcrossProviders`
- [ ] `relativeTimeBuckets`

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

- [ ] `sumsOnlySamplesInsideWindow`
- [ ] `weightedTokensDiscountCacheReads`
- [ ] `percentUsesConfiguredCapacity`
- [ ] `percentNilWithoutCapacity`
- [ ] `codexRollingCapacityProducesPercent`
- [ ] `percentClampsAtZero`
- [ ] `tokensFormatting`

## UsageSource (12)

- [ ] `parsesClaudeAssistantLine`
- [ ] `ignoresUserLines`
- [ ] `skipsSyntheticClaudeTurns`
- [ ] `dedupesRepeatedRequestIdsKeepingLast`
- [ ] `codexTakesLastCumulativeEvent`
- [ ] `codexLocalProviderProducesRemainingPercent`
- [ ] `parsesOpenCodeMessageJSON`
- [ ] `parsesOpenCodeSQLiteSnapshot`
- [ ] `parsesNewOpenCodeSessionMessage`
- [ ] `parsesNewOpenCodeSQLiteSchema`
- [ ] `querySamplesUsesInjectedSQLiteRunner`
- [ ] `fileManagerPathsAppendsAppName`

## Non-test parity work

- [ ] Menu structure matches `StatusMenuBuilder` (`mainMenu`, `widgetMenu`,
      `chartsRowIsOptIn` → `Charts…` only on Linux/Windows)
- [ ] Icon spec/severity stops match `StatusIcon`
- [ ] Relative-time formatting matches `RelativeTime`
- [ ] Per-OS credential paths match `AppPaths` (`dataDirectory`/`configDirectory`
      honouring XDG; macOS Keychain via `security`)
- [ ] `rusqlite` (bundled, read-only) replaces shelling out to `/usr/bin/sqlite3`
- [ ] Provider diagnostics (`lastStatus`) surfaced in the UI

