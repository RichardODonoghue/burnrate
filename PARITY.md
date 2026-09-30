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

## Closed

- [x] **Window-reset alerting.** Ported signal for signal: the vendor moving a
      window's reset time forward is the primary signal, and a ≥40-point jump is
      the fallback for sources that report no reset time. The 5-point threshold
      this used is *not* equivalent — a quiet window gains 5 points from cache
      expiry alone, and an old window can end at >90% so the deadline signal is
      the only one that catches it. Tests for both signals, for a drift that must
      *not* fire, and for the first reading having no baseline.
- [x] **Claude account fingerprint.** `~/.claude.json`'s
      `oauthAccount.accountUuid|organizationUuid`, falling back to a stable token
      hash. Verified reading this machine's real account file.
- [x] **Notifier state persistence.** `notifier-state.json` holds the account
      fingerprint, every window's last reading and reset time, and the days a
      spend cap already fired — the Swift build's `notifierState`. It matters
      because restoring the baseline is what makes the saved fingerprint
      load-bearing: without both, a switch across a relaunch is invisible.
- [x] **Daily/ranking token-axis format.** `axis_label` is a tested core function
      with `%g` semantics, and the daily axis labels and ticks arrive
      pre-formatted from Rust. The frontend does no arithmetic.

## Still open

- **Not tested end to end:** the two notification paths I cannot exercise from a
  terminal-launched process — a foreground banner, and a real macOS banner rather
  than a delivered request. The delegate is verified installed and responding.

## Icon and asset parity (macOS is the reference)

- [x] Flame + dial geometry ported (`burnrate_core::dial`), mean channel diff
      **6.5/255** against the shipped `Resources/AppIcon.icns` — antialiasing only
- [x] Needle angle + severity ramp ported and **byte-identical** to Swift
      (`scripts/xcheck_core.sh` diffs the two implementations)
- [x] Menu-bar image is monochrome (macOS template), dial punched out of the flame
- [x] Assets generated from that one source: `cargo run -p icon-gen`
      (PNG set, `.icns`, `.ico`, `tray.rgba`) — no hand-drawn art anywhere
- [x] **App-icon pose: amber, as shipped.** The committed icns is *stale*: it predates
      the Sep-2026 severity-ramp refactor and is **amber** (`rgb(255,149,66)`),
      while `AppIconRenderer.appIconImage` passes `nil`, which the ramp reads as
      70% and paints **green**. Confirmed as shipped: the port defaults to amber
      via `dial::SHIPPED_ICON_POSE_REMAINING`, which is what is visible today.
- [x] App icon radius/border and dial rim match at every size
- [x] The menu-bar mark fills its canvas. It inked 74% of the design space, and
      `tray-icon` scales the whole canvas to 18pt, so it drew at 13.4pt; a
      design-space zoom now puts the ink at 89% and ~16pt, centred on the ink
      rather than on the canvas. Tests pin the fill fraction, the centring, and
      that the app icon keeps its own framing.

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
