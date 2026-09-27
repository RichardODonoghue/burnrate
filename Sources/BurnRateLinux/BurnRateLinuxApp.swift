import BurnRateCore
import CBurnRateGTK
import CBurnRateTray
import Foundation
import Glibc

/// One provider's local-log samples for the dashboard.
private struct Bucket: Sendable {
    let provider: String
    let samples: [UsageSample]
}

/// Everything the window needs for one poll. Cached so that changing a picker
/// re-renders instantly instead of re-scanning every usage log.
private struct DashboardSnapshot: Sendable {
    var usage: [ProviderUsage] = []
    var buckets: [Bucket] = []
    var costs: [(provider: String, cost: Double)] = []
    var missing: [String] = []
}

/// Fetches usage from every configured provider.
private actor LinuxPoller {
    private let claude = ClaudeUsageAPIProvider()
    private let openCode = OpenCodeGoUsageAPIProvider()
    private let local = LocalUsageProvider(source: CodexUsageSource())
    private let costSources: [(name: String, source: any UsageSource)]

    init() {
        self.costSources = [
            ("Claude", ClaudeUsageSource()),
            ("OpenCode", OpenCodeUsageSource()),
            ("Codex", CodexUsageSource()),
        ]
    }

    /// One line per provider that produced nothing, explaining why.
    private func diagnostics() async -> [String] {
        var lines: [String] = []
        if await claude.lastStatus != nil { lines.append("Claude: \(await claude.lastStatus!)") }
        if await openCode.lastStatus != nil { lines.append("OpenCode: \(await openCode.lastStatus!)") }
        if await local.lastStatus != nil { lines.append("Codex: \(await local.lastStatus!)") }
        return lines
    }

    func snapshot() async -> DashboardSnapshot {
        var snapshot = DashboardSnapshot()
        let providers: [any UsageProvider] = [claude, openCode, local]
        for provider in providers {
            if let result = await provider.fetchUsage(capacities: PlanCapacities.byProviderWindow) {
                snapshot.usage.append(result)
            }
        }
        snapshot.missing = await diagnostics()
        notifier.lastError.map { snapshot.missing.append($0) }

        let todayStart = Calendar.current.startOfDay(for: Date())
        for (name, source) in costSources {
            let samples = (try? await source.collectSamples()) ?? []
            snapshot.buckets.append(Bucket(provider: name, samples: samples))
            let spend = samples
                .filter { $0.timestamp >= todayStart }
                .reduce(0.0) { $0 + PricingService.shared.cost(of: $1) }
            snapshot.costs.append((name, spend))
        }
        return snapshot
    }
}

/// Per-tray click handlers, guarded because D-Bus callbacks arrive on other threads.
private final class ActionStore: @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [StatusMenuAction] = []

    func replace(_ newActions: [StatusMenuAction]) {
        lock.withLock { actions = newActions }
    }

    func action(at index: Int32) -> StatusMenuAction? {
        lock.withLock { (index >= 0 && Int(index) < actions.count) ? actions[Int(index)] : nil }
    }
}

/// Shared app state, guarded for access from the GTK thread, D-Bus callbacks
/// and the background poller.
private final class AppState: @unchecked Sendable {
    private let lock = NSLock()
    private var _mainTray: Int32 = -1
    private var _trayActions: [Int32: ActionStore] = [:]
    private var _widgetTrays: [String: Int32] = [:]
    private var _settingsProviders: [String] = []
    private var _lastUsage: [ProviderUsage] = []

    var mainTray: Int32 { lock.withLock { _mainTray } }
    func setMainTray(_ value: Int32) { lock.withLock { _mainTray = value } }

    func actionStore(_ tray: Int32) -> ActionStore? { lock.withLock { _trayActions[tray] } }
    func setActionStore(_ store: ActionStore, for tray: Int32) { lock.withLock { _trayActions[tray] = store } }
    func removeActionStore(_ tray: Int32) { lock.withLock { _ = _trayActions.removeValue(forKey: tray) } }

    func widgetTrays() -> [String: Int32] { lock.withLock { _widgetTrays } }
    func widgetTray(_ provider: String) -> Int32? { lock.withLock { _widgetTrays[provider] } }
    func setWidgetTray(_ tray: Int32, for provider: String) { lock.withLock { _widgetTrays[provider] = tray } }
    func removeWidgetTray(_ provider: String) -> Int32? { lock.withLock { _widgetTrays.removeValue(forKey: provider) } }

    var settingsProviders: [String] { lock.withLock { _settingsProviders } }
    func setSettingsProviders(_ providers: [String]) { lock.withLock { _settingsProviders = providers } }

    func lastUsage() -> [ProviderUsage] { lock.withLock { _lastUsage } }
    func setLastUsage(_ usage: [ProviderUsage]) { lock.withLock { _lastUsage = usage } }

    /// Last poll's data plus the selection to render it for, so a picker change
    /// re-renders from cache instead of re-scanning every usage log.
    private var _snapshot: DashboardSnapshot?
    private var _query: br_query?
    func snapshot() -> DashboardSnapshot? { lock.withLock { _snapshot } }
    func setSnapshot(_ value: DashboardSnapshot?) { lock.withLock { _snapshot = value } }
    func query() -> br_query? { lock.withLock { _query } }
    func setQuery(_ value: br_query) { lock.withLock { _query = value } }
}

private let poller = LinuxPoller()
private let settings = LinuxSettings()
private let notifier = LinuxNotifier(settings: settings)
private let state = AppState()

/// Remaining-% history for the trend chart. Persisted, not just in memory:
/// a 5-minute poll only yields ~288 points a day, so losing the file on every
/// restart would leave the trend chart permanently empty until you had been
/// running for a week.
private final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [RemainingSample] = []
    private let paths: any AppPaths
    private static let retention: TimeInterval = 7 * 86400
    private static let file = "remaining-history.json"

    init(paths: any AppPaths = FileManagerPaths()) {
        self.paths = paths
        let loaded = AppStateFiles.load([RemainingSample].self, from: Self.file, paths: paths) ?? []
        let cutoff = Date().addingTimeInterval(-Self.retention)
        samples = loaded.filter { $0.date >= cutoff }
    }

    func append(usage: [ProviderUsage], date: Date) {
        lock.withLock {
            for entry in usage {
                for window in entry.windows {
                    guard let remaining = window.percentRemaining else { continue }
                    samples.append(RemainingSample(provider: entry.providerName, label: window.label,
                                                   date: date, remaining: remaining))
                }
            }
            let cutoff = date.addingTimeInterval(-Self.retention)
            samples = samples.filter { $0.date >= cutoff }
            AppStateFiles.save(samples, to: Self.file, paths: paths)
        }
    }

    func snapshot() -> [RemainingSample] { lock.withLock { samples } }
}

private let history = HistoryStore()

private func providerRGB(_ provider: String) -> (Double, Double, Double) {
    switch provider {
    case "Claude": (0.85, 0.47, 0.34)
    case "OpenCode Go", "OpenCode": (0.25, 0.55, 0.95)
    case "Codex": (0.20, 0.68, 0.44)
    default: (0.6, 0.6, 0.6)
    }
}

/// The symbolic icon installed by `make_linux_app.sh`. Panels recolour
/// symbolic icons from the theme, which is what the macOS status item gets from
/// its template image.
private let trayIconName = "burnrate-symbolic"

/// Matches the desktop file / package version. The Linux app is installed
/// unpackaged, so there is no bundle to read an Info.plist from.
private let appVersion = "0.8.0"

/// The hicolor directory the app's icons were installed into, so the GTK icon
/// theme can resolve `burnrate` without waiting for a cache rebuild. Returns
/// nil when nothing is installed.
private func installedIconDir() -> String? {
    let relative = "icons/hicolor"
    var roots: [URL] = []
    if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
        roots.append(URL(fileURLWithPath: xdg, isDirectory: true))
    }
    roots.append(FileManagerPaths().homeDirectory
        .appendingPathComponent(".local/share"))
    roots.append(URL(fileURLWithPath: "/usr/share", isDirectory: true))
    roots.append(URL(fileURLWithPath: "/usr/local/share", isDirectory: true))
    for root in roots {
        let dir = root.appendingPathComponent(relative)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return dir.path
        }
    }
    return nil
}

/// One provider's entry for one day, with the metric the user selected.
private func metricValue(_ entry: ModelUsageEntry, cost: Bool) -> Double {
    cost ? entry.cost : Double(entry.totalTokens)
}

/// Builds the whole window contents for one query. This is the only place that
/// knows how a selection maps onto data — the GTK layer just draws what comes
/// out, so adding a control means adding a field here and a widget there, not
/// inventing a parallel data path.
private func buildView(_ query: br_query, snapshot: DashboardSnapshot?) -> UnsafeMutablePointer<br_view>! {
    let view = br_view_new()!
    view.pointee.version = br_dup(appVersion)

    // The provider list must stay stable across refreshes or the dropdown's
    // selection would silently jump. "All" is always index 0.
    let names = ["All"] + Array(Set(snapshot?.buckets.map(\.provider) ?? [])).sorted()
    view.pointee.providers = dupCStrings(names)
    view.pointee.provider_count = Int32(names.count)
    let providerFilter: String? = {
        let index = Int(query.provider)
        guard index > 0, index < names.count else { return nil }
        return names[index]
    }()

    let cost = Int(query.metric) == BR_METRIC_COST
    let range: ChartRange = switch Int(query.range) {
    case BR_RANGE_24H: .today
    case BR_RANGE_30D: .month
    default: .week
    }

    let buckets = (snapshot?.buckets ?? []).filter { bucket in
        providerFilter == nil || bucket.provider == providerFilter
    }
    let rawTotals = ModelUsageAggregator.totals(
        buckets: buckets.map { (provider: $0.provider, samples: $0.samples) })

    // ---- cards -------------------------------------------------------------
    let latest = TrendChartData.latestRolling(
        samples: history.snapshot(), providerFilter: providerFilter)
    let todayEntries: [ModelUsageEntry] = {
        guard let day = TrendChartData.dayBucket(
            for: Date(), in: ModelUsageAggregator.daily(
                buckets: buckets.map { (provider: $0.provider, samples: $0.samples) },
                days: Int(range.span / 86400) + 1))
        else { return [] }
        return day.entries
    }()

    var cards: [br_card] = []
    for item in latest {
        cards.append(br_card(
            label: br_dup("\(item.provider) · rolling"),
            value: br_dup(String(format: "%.0f%%", item.remaining)),
            detail: nil))
    }
    let tokenTotal = todayEntries.reduce(0) { $0 + $1.totalTokens }
    let requestTotal = todayEntries.reduce(0) { $0 + $1.requests }
    cards.append(br_card(
        label: br_dup("Tokens today"),
        value: br_dup(tokenTotal > 0 ? TokenFormat.format(tokenTotal) : "—"),
        detail: br_dup("\(requestTotal) requests")))
    let costTotal = todayEntries.reduce(0.0) { $0 + $1.cost }
    cards.append(br_card(
        label: br_dup("Cost today"),
        value: br_dup(costTotal > 0 ? String(format: "$%.2f", costTotal) : "—"),
        detail: br_dup("list-price estimate")))
    if !cards.isEmpty {
        let buffer = alloc(br_card.self, cards.count)
        for (index, card) in cards.enumerated() { buffer[index] = card }
        view.pointee.cards = buffer
        view.pointee.card_count = Int32(cards.count)
    }

    // ---- trend -------------------------------------------------------------
    let cutoff = TrendChartData.trendCutoff(for: range, now: Date())
    let now = Date()
    let span = max(now.timeIntervalSince(cutoff), 1)
    let availableLabels = trendLabels(samples: history.snapshot(), range: range,
                                      providerFilter: providerFilter)
    view.pointee.trend_labels = dupCStrings(availableLabels)
    view.pointee.trend_label_count = Int32(availableLabels.count)
    let labelIndex = Int(query.trend_label)
    let label = (labelIndex >= 0 && labelIndex < availableLabels.count)
        ? availableLabels[labelIndex] : (availableLabels.first ?? "Rolling")

    let series = TrendChartData.buildTrendSeries(
        samples: history.snapshot(), label: label,
        providerFilter: providerFilter, cutoff: cutoff)
    if !series.isEmpty {
        let buffer = alloc(br_series.self, series.count)
        for (index, item) in series.enumerated() {
            let color = providerRGB(item.provider)
            let points = alloc(br_xy.self, item.samples.count)
            for (j, sample) in item.samples.enumerated() {
                points[j] = br_xy(
                    x: max(0, min(1, sample.date.timeIntervalSince(cutoff) / span)),
                    y: sample.remaining)
            }
            buffer[index] = br_series(
                name: br_dup(item.name), rgb: (color.0, color.1, color.2),
                dashed: item.scoped ? 1 : 0, count: Int32(item.samples.count), pts: points)
        }
        view.pointee.series = buffer
        view.pointee.series_count = Int32(series.count)

        // x-axis ticks, formatted here so the C layer needs no date code.
        let ticks = TrendChartData.trendTickDates(cutoff: cutoff, now: now)
        view.pointee.x_labels = dupCStrings(ticks.map { TrendChartData.trendTickLabel($0) })
        view.pointee.x_label_count = Int32(ticks.count)
    }

    // ---- daily + ranking ---------------------------------------------------
    let dayCount = Int(range.span / 86400) + 1
    let daily = ModelUsageAggregator.daily(
        buckets: buckets.map { (provider: $0.provider, samples: $0.samples) }, days: dayCount)
    if !daily.isEmpty {
        var segments: [br_seg] = []
        for (dayIndex, day) in daily.enumerated() {
            for entry in day.entries {
                let color = modelColor(entry.displayName)
                segments.append(br_seg(
                    day: Int32(dayIndex), value: metricValue(entry, cost: cost),
                    rgb: (color.0, color.1, color.2)))
            }
        }
        let buffer = alloc(br_seg.self, segments.count)
        for (index, segment) in segments.enumerated() { buffer[index] = segment }
        view.pointee.segments = buffer
        view.pointee.segment_count = Int32(segments.count)
        view.pointee.day_count = Int32(daily.count)
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = range == .today ? "HH:mm" : "d MMM"
        view.pointee.day_labels = dupCStrings(daily.map { dayFormatter.string(from: $0.day) })
        view.pointee.day_label_count = Int32(daily.count)

        // Per-day tooltip text. Formatted here because only this side knows the
        // metric: a raw token count is unreadable, and a $0.003 cost printed
        // with "%.0f" is just "0".
        var tips: [br_day_tip] = []
        for day in daily {
            let ranked = day.entries
                .sorted { metricValue($0, cost: cost) > metricValue($1, cost: cost) }
            let total = ranked.reduce(0.0) { $0 + metricValue($1, cost: cost) }
            let totalText = total > 0
                ? (cost ? String(format: "$%.2f", total) : "\(TokenFormat.format(Int(total))) tokens")
                : "—"
            let details = ranked.prefix(5)
                .map { entry in
                    cost ? String(format: "%@  $%.2f", entry.displayName, entry.cost)
                         : "\(entry.displayName)  \(TokenFormat.format(entry.totalTokens))"
                }
                .joined(separator: "\n")
            tips.append(br_day_tip(total: br_dup(totalText),
                                   details: br_dup(details)))
        }
        if !tips.isEmpty {
            let tipBuffer = alloc(br_day_tip.self, tips.count)
            for (index, tip) in tips.enumerated() { tipBuffer[index] = tip }
            view.pointee.day_tips = tipBuffer
        }
    }

    let ranked = Array(rawTotals.prefix(8))
    if !ranked.isEmpty {
        let peak = ranked.map { metricValue($0, cost: cost) }.max() ?? 1
        let buffer = alloc(br_bar.self, ranked.count)
        for (index, entry) in ranked.enumerated() {
            let color = modelColor(entry.displayName)
            let value = metricValue(entry, cost: cost)
            buffer[index] = br_bar(
                label: br_dup(cost
                    ? String(format: "%@ $%.2f", entry.displayName, entry.cost)
                    : "\(entry.displayName) · \(TokenFormat.format(entry.totalTokens))"),
                value: peak > 0 ? value / peak : 0,
                rgb: (color.0, color.1, color.2))
        }
        view.pointee.bars = buffer
        view.pointee.bar_count = Int32(ranked.count)
    }

    // ---- per-model breakdown table ----------------------------------------
    if !rawTotals.isEmpty {
        var rows: [br_row] = []
        rows.append(br_row(cells: rowCells(["Model", "Tokens", "Requests", "Cost"]),
                           cell_count: 4))
        for entry in rawTotals.prefix(20) {
            rows.append(br_row(cells: rowCells([
                entry.displayName,
                TokenFormat.format(entry.totalTokens),
                "\(entry.requests)",
                entry.cost > 0 ? String(format: "$%.2f", entry.cost) : "—",
            ]), cell_count: 4))
        }
        let buffer = alloc(br_row.self, rows.count)
        for (index, row) in rows.enumerated() { buffer[index] = row }
        view.pointee.rows = buffer
        view.pointee.row_count = Int32(rows.count)
    }

    // ---- status + diagnostics ---------------------------------------------
    if snapshot == nil {
        view.pointee.status = br_dup("Loading usage…")
    } else if series.isEmpty && daily.isEmpty && ranked.isEmpty {
        view.pointee.status = br_dup("No usage data yet. It appears once the local logs contain data, "
            + "or a plan reports usage.")
    } else if snapshot!.usage.isEmpty {
        view.pointee.status = br_dup("No providers found — log in to a supported CLI, then press Refresh.")
    }
    if let missing = snapshot?.missing, !missing.isEmpty {
        view.pointee.diagnostics = br_dup(
            ("Not working:\n" + missing.map { "  \($0)" }.joined(separator: "\n")))
    }
    return view
}

/// Window labels that actually have data in the range, so the picker never
/// offers a window that would render an empty chart.
private func trendLabels(samples: [RemainingSample], range: ChartRange,
                         providerFilter: String?) -> [String] {
    let cutoff = TrendChartData.trendCutoff(for: range, now: Date())
    func hasData(_ label: String) -> Bool {
        samples.contains {
            $0.date >= cutoff
                && TrendChartData.canonicalTrendLabel($0.label) == label
                && (providerFilter == nil || $0.provider == providerFilter)
        }
    }
    // Every window that has data in the range, in canonical order — so the
    // filter offers Rolling/Weekly/Monthly like macOS, not just the first hit.
    let present = ["Rolling", "Weekly", "Monthly"].filter(hasData)
    return present.isEmpty ? ["Rolling"] : present
}

private func modelColor(_ name: String) -> (Double, Double, Double) {
    let palette: [(Double, Double, Double)] = [
        (0.85, 0.47, 0.34), (0.25, 0.55, 0.95), (0.20, 0.68, 0.44), (0.72, 0.45, 0.85),
        (0.95, 0.62, 0.24), (0.30, 0.72, 0.78), (0.83, 0.36, 0.55), (0.55, 0.60, 0.35),
    ]
    var hash: UInt64 = 5381
    for byte in name.utf8 { hash = (hash &* 33) &+ UInt64(byte) }
    return palette[Int(hash % UInt64(palette.count))]
}

/// Allocator for the view-model arrays the GTK layer will free.
///
/// Goes through `br_alloc` (GLib, zeroed) rather than Swift's `allocate`, so
/// the matching `g_free` in `view_clear` uses the same allocator — and so an
/// unset field is nil rather than uninitialised memory.
private func alloc<T>(_ type: T.Type, _ count: Int) -> UnsafeMutablePointer<T> {
    UnsafeMutablePointer<T>(br_alloc(MemoryLayout<T>.stride * count)
        .assumingMemoryBound(to: T.self))
}

/// C-owned copies of a string array, for a view the GTK layer will free.
private func dupCStrings(_ items: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>? {
    guard !items.isEmpty else { return nil }
    let buffer = alloc(UnsafeMutablePointer<CChar>?.self, items.count)
    for (index, item) in items.enumerated() { buffer[index] = br_dup(item) }
    return buffer
}

/// The same, for a row's fixed five-cell array, which C imports as a tuple.
private func rowCells(_ items: [String]) -> (UnsafeMutablePointer<CChar>?,
                                            UnsafeMutablePointer<CChar>?,
                                            UnsafeMutablePointer<CChar>?,
                                            UnsafeMutablePointer<CChar>?,
                                            UnsafeMutablePointer<CChar>?) {
    var cells: [UnsafeMutablePointer<CChar>?] = items.map { br_dup($0) }
    while cells.count < 5 { cells.append(nil) }
    return (cells[0], cells[1], cells[2], cells[3], cells[4])
}

/// Opens the GitHub releases page in the desktop browser (Linux has no in-app
/// updater yet). Tries the usual openers, since a hardcoded path only works on
/// the distro it was written on.
private func openReleases() {
    let url = "https://github.com/RichardODonoghue/burnrate/releases"
    // (tool, leading arguments) — first one present on PATH wins.
    let openers: [(tool: String, arguments: [String])] = [
        ("xdg-open", []),
        ("gio", ["open"]),
        ("sensible-browser", []),
        ("x-www-browser", []),
        ("gnome-open", []),
        ("kde-open", []),
    ]
    for opener in openers {
        guard let path = ExternalTool.locate(named: opener.tool) else { continue }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = opener.arguments + [url]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        return
    }
}

private func handleAction(_ action: StatusMenuAction) {
    switch action {
    case .openDashboard:
        break // the window is already presented on Linux
    case .openCharts:
        br_ui_show_pane(Int32(BR_PANE_USAGE))
    case .openSettings:
        showSettings()
    case .checkForUpdates, .installUpdate:
        openReleases()
    case .quit:
        br_ui_quit()
    case .removeWidget(let provider):
        settings.setWidget(provider, enabled: false)
        syncWidgetTrays()
    }
}

private func onTrayAction(_ tray: Int32, _ actionID: Int32, _ context: UnsafeMutableRawPointer?) {
    if let action = state.actionStore(tray)?.action(at: actionID) {
        handleAction(action)
    }
}

/// Builds `br_tray_item`s for a model and records the actions for `tray`.
private func setTrayItems(_ tray: Int32, model: StatusMenuModel) {
    var rows: [(label: String, action: Int32, enabled: Bool)] = []
    var actions: [StatusMenuAction] = []
    for entry in model.entries {
        switch entry {
        case .providerHeader(let title):
            rows.append((title, -1, false))
        case .windowRow(let label, let detail):
            rows.append(("  \(label): \(detail)", -1, false))
        case .text(let text):
            rows.append((text, -1, false))
        case .separator:
            rows.append(("", -2, false))
        case .action(let title, let action, let isEnabled):
            rows.append((title, Int32(actions.count), isEnabled))
            actions.append(action)
        }
    }

    var pointers: [UnsafeMutablePointer<CChar>?] = []
    var items: [br_tray_item] = []
    for row in rows {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        items.append(br_tray_item(label: pointer.map { UnsafePointer($0) },
                                  action_id: row.action,
                                  enabled: row.enabled ? 1 : 0))
    }
    items.withUnsafeBufferPointer { buffer in
        br_tray_set_items(tray, buffer.baseAddress, Int32(buffer.count))
    }
    for pointer in pointers { free(pointer) }

    state.actionStore(tray)?.replace(actions)
}

private func updateMainTray(usage: [ProviderUsage], diagnostics: [String]) {
    guard state.mainTray >= 0 else { return }
    // Show the worst rolling remaining as the item's visible label, the way the
    // macOS status item bakes it into its icon. Without this the menu-bar item
    // read a static "BurnRate", and the numbers were only visible after opening
    // the dropdown or the dashboard window.
    let remaining = StatusMenuBuilder.worstRollingRemaining(usage: usage)
    br_tray_set_title(state.mainTray, remaining.map { String(format: "%.0f%%", $0) } ?? "BurnRate")
    setTrayItems(state.mainTray, model: StatusMenuBuilder.mainMenu(
        usage: usage, updateVersion: nil, isBusy: false, includesCharts: true,
        diagnostics: diagnostics))
}

/// Creates/removes per-provider widget trays to match settings.
private func syncWidgetTrays(usage: [ProviderUsage]? = nil) {
    let enabled = settings.snapshot.widgetProviders
    let currentUsage = usage ?? state.lastUsage()

    // Remove disabled widgets.
    for (provider, tray) in state.widgetTrays() where !enabled.contains(provider) {
        br_tray_remove(tray)
        _ = state.removeWidgetTray(provider)
        state.removeActionStore(tray)
    }

    // Add/update enabled widgets (each is its own tray item).
    for provider in enabled {
        var tray = state.widgetTray(provider)
        if tray == nil {
            let created = trayIconName.withCString {
                br_tray_add($0, provider, onTrayAction, nil)
            }
            if created >= 0 {
                tray = created
                state.setWidgetTray(created, for: provider)
                state.setActionStore(ActionStore(), for: created)
            }
        }
        guard let tray else { continue }
        let widget = StatusMenuBuilder.widget(
            provider: provider, usage: currentUsage.first { $0.providerName == provider })
        br_tray_set_title(tray, widget.title)
        setTrayItems(tray, model: widget.menu)
    }
}

/// GTK calls this on the main thread when a settings checkbox is toggled.
private func onSettingsToggle(_ id: Int32, _ checked: Int32, _ context: UnsafeMutableRawPointer?) {
    let enabled = checked != 0
    if id == 0 {
        settings.setNotifyOnReset(enabled)
        return
    }
    let providers = state.settingsProviders
    let index = Int(id) - 1
    guard index >= 0, index < providers.count else { return }
    settings.setWidget(providers[index], enabled: enabled)
    syncWidgetTrays()
}

/// GTK calls this on the main thread when a milestone step changes.
private func onSettingsSpin(_ id: Int32, _ value: Double, _ context: UnsafeMutableRawPointer?) {
    switch id {
    case 1000..<2000:
        settings.setMilestoneStep(at: Int(id) - 1000, step: value.rounded())
    case 2000..<3000:
        settings.setBurnAlert(at: Int(id) - 2000, drop: value.rounded(), minutes: nil)
    case 3000..<4000:
        settings.setBurnAlert(at: Int(id) - 3000, drop: nil, minutes: value.rounded())
    case 4000..<5000:
        settings.setCostAlertLimit(at: Int(id) - 4000, limit: value)
    default:
        break
    }
}

private func showSettings() {
    let providers = state.lastUsage().map(\.providerName).sorted()
    state.setSettingsProviders(providers)
    let values = settings.snapshot

    var checks: [(label: String, id: Int32, checked: Bool)] = [
        ("Notify when a window resets", 0, values.notifyOnReset),
    ]
    for (index, provider) in providers.enumerated() {
        checks.append(("Menu-bar widget for \(provider)", Int32(index + 1),
                       values.widgetProviders.contains(provider)))
    }

    var spins: [(label: String, id: Int32, value: Double, minimum: Double, maximum: Double)] = []
    for (index, milestone) in values.milestones.enumerated() {
        spins.append(("\(milestone.provider) \(milestone.windowLabel) — every %",
                      Int32(1000 + index), milestone.step, 5, 50))
    }
    for (index, alert) in values.burnAlerts.enumerated() {
        spins.append(("\(alert.provider) \(alert.windowLabel) burn drop %",
                      Int32(2000 + index), alert.percentDrop, 5, 95))
        spins.append(("\(alert.provider) \(alert.windowLabel) burn window (min)",
                      Int32(3000 + index), Double(alert.minutes), 15, 120))
    }
    for (index, alert) in values.costAlerts.enumerated() {
        spins.append(("\(alert.provider) daily limit $",
                      Int32(4000 + index), alert.dailyLimitUSD, 1, 1000))
    }

    var pointers: [UnsafeMutablePointer<CChar>?] = []
    var checkItems: [br_checkbox] = []
    for row in checks {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        checkItems.append(br_checkbox(label: pointer.map { UnsafePointer($0) }, id: row.id,
                                      checked: row.checked ? 1 : 0))
    }
    var spinItems: [br_spin] = []
    for row in spins {
        let pointer = strdup(row.label)
        pointers.append(pointer)
        spinItems.append(br_spin(label: pointer.map { UnsafePointer($0) }, id: row.id,
                                 value: row.value, minimum: row.minimum, maximum: row.maximum))
    }

    checkItems.withUnsafeBufferPointer { checkBuffer in
        spinItems.withUnsafeBufferPointer { spinBuffer in
            br_settings_show("BurnRate Settings",
                             checkBuffer.baseAddress, Int32(checkBuffer.count),
                             spinBuffer.baseAddress, Int32(spinBuffer.count),
                             onSettingsToggle, onSettingsSpin, nil)
        }
    }
    for pointer in pointers { free(pointer) }
}

/// GTK calls this on the main thread (window shown, Refresh, 5-min timer).
private func onRefresh(_ context: UnsafeMutableRawPointer?) {
    Task.detached {
        let result = await poller.snapshot()
        if !result.missing.isEmpty {
            NSLog("%@", "BurnRate: providers not detected — " + result.missing.joined(separator: " | "))
        }
        history.append(usage: result.usage, date: Date())
        state.setLastUsage(result.usage)
        state.setSnapshot(result)
        updateMainTray(usage: result.usage, diagnostics: result.missing)
        syncWidgetTrays(usage: result.usage)
        notifier.evaluate(result.usage)
        notifier.evaluateCosts(result.costs)
        // Hop back to the GTK thread for the window rebuild: the usage view
        // model and the settings panes both construct widget-facing state.
        br_ui_refresh_on_main()
    }
}

/// GTK calls this on the main thread whenever a picker or pane changes. It must
/// return immediately — the redraw happens when `br_ui_present` lands.
private func onQuery(_ query: br_query, _ context: UnsafeMutableRawPointer?) {
    state.setQuery(query)
    presentWindow()
}

private func presentWindow() {
    guard let query = state.query() else { return }
    br_ui_present(buildView(query, snapshot: state.snapshot()))
    presentSettingsPane()
}

/// The settings panes are static apart from the rule rows, so they are rebuilt
/// from the settings file rather than carried in the usage view model.
private func presentSettingsPane() {
    let values = settings.snapshot
    let payload = br_settings_new()!
    payload.pointee.notify_on_reset = values.notifyOnReset ? 1 : 0

    let alertsTool = ExternalTool.locate(named: "notify-send") != nil
    payload.pointee.alerts_ok = alertsTool ? 1 : 0
    payload.pointee.alerts_status = br_dup(alertsTool
        ? "Desktop alerts are available (notify-send)."
        : "Desktop alerts are unavailable — notify-send was not found on PATH.")
    payload.pointee.version = br_dup("Version \(appVersion)")

    var rules: [br_rule] = []
    for milestone in values.milestones {
        let rgb = providerRGB(milestone.provider)
        rules.append(br_rule(
            kind: Int32(BR_RULE_MILESTONE), provider: br_dup(milestone.provider),
            window_label: br_dup(milestone.windowLabel), step: milestone.step,
            percent_drop: 0, minutes: 0, cost_limit: 0,
            // Same wording as the macOS chip.
            chip: br_dup("Every \(Int(milestone.step))%"),
            rgb: (rgb.0, rgb.1, rgb.2)))
    }
    for alert in values.burnAlerts {
        rules.append(br_rule(
            kind: Int32(BR_RULE_BURN), provider: br_dup(alert.provider),
            window_label: br_dup(alert.windowLabel), step: 0,
            percent_drop: alert.percentDrop, minutes: Int32(alert.minutes), cost_limit: 0,
            chip: br_dup(String(format: "↓%.0f%% / %d min", alert.percentDrop, alert.minutes)),
            rgb: (0.95, 0.55, 0.15)))
    }
    for alert in values.costAlerts {
        rules.append(br_rule(
            kind: Int32(BR_RULE_COST), provider: br_dup(alert.provider), window_label: nil,
            step: 0, percent_drop: 0, minutes: 0, cost_limit: alert.dailyLimitUSD,
            chip: br_dup(String(format: "≥ $%.2f/day", alert.dailyLimitUSD)),
            rgb: (0.20, 0.68, 0.44)))
    }
    if !rules.isEmpty {
        let buffer = alloc(br_rule.self, rules.count)
        for (index, rule) in rules.enumerated() { buffer[index] = rule }
        payload.pointee.rules = buffer
        payload.pointee.rule_count = Int32(rules.count)
    }

    // Provider and window choices come from live usage, so the pickers only ever
    // offer pairs that actually exist.
    let snapshot = state.snapshot()
    let providerNames = (snapshot?.usage.map(\.providerName) ?? []).sorted()
    let windowLabels = orderedWindowLabels()
    let widgets = alloc(Int32.self, max(providerNames.count, 1))
    for (index, name) in providerNames.enumerated() {
        widgets[index] = values.widgetProviders.contains(name) ? 1 : 0
    }
    payload.pointee.widgets_on = UnsafeMutablePointer<Int32>(widgets)
    payload.pointee.widget_count = Int32(providerNames.count)
    payload.pointee.version = br_dup("Version \(appVersion)")

    // `br_settings_present` takes ownership of the payload; freeing it here
    // would leave the panes holding pointers that were already released.
    br_settings_present(payload, dupCStrings(providerNames), Int32(providerNames.count),
                        dupCStrings(windowLabels), Int32(windowLabels.count),
                        onSettingsAction, nil)
}

/// Canonical window order, restricted to what the providers actually report.
private func orderedWindowLabels() -> [String] {
    let usage = state.snapshot()?.usage ?? []
    let present = Set(usage.flatMap { entry in entry.windows.map(\.label) })
    let ordered = ["Rolling", "Weekly", "Monthly"].filter { present.contains($0) }
    return ordered.isEmpty ? ["Rolling"] : ordered
}

/// The add form's state, mirroring macOS's `@State` in MilestonesView.
private final class DraftState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int: Double] = [:]
    private var _minutes = 30
    var provider = ""
    var window = "Rolling"
    var minutes: Int { lock.withLock { _minutes } }

    func set(_ value: Double, for card: Int) {
        lock.withLock { values[card] = value }
        if card == BR_RULE_BURN { lock.withLock { _minutes = 30 } }
    }

    func value(for card: Int) -> Double {
        lock.withLock { values[card] ?? (card == BR_RULE_MILESTONE ? 20 : 20) }
    }
}

private let draft = DraftState()

/// GTK calls this on the main thread for every settings edit.
private func onSettingsAction(_ action: Int32, _ index: Int32, _ provider: UnsafePointer<CChar>?,
                              _ windowLabel: UnsafePointer<CChar>?, _ value: Double,
                              _ context: UnsafeMutableRawPointer?) {
    let i = Int(index)
    switch Int(action) {
    case BR_ACT_RESET_TOGGLE:
        settings.setNotifyOnReset(value != 0)
    case BR_ACT_RULE_STEP:
        settings.setMilestoneStep(at: i, step: value.rounded())
    case BR_ACT_RULE_DROP, BR_ACT_RULE_MINUTES:
        let values = settings.snapshot
        let j = i - values.milestones.count
        guard j >= 0, j < values.burnAlerts.count else { return }
        settings.setBurnAlert(at: j,
                              drop: action == BR_ACT_RULE_DROP ? value.rounded() : nil,
                              minutes: action == BR_ACT_RULE_MINUTES ? Double(value.rounded()) : nil)
    case BR_ACT_RULE_COST:
        let values = settings.snapshot
        let j = i - values.milestones.count - values.burnAlerts.count
        guard j >= 0, j < values.costAlerts.count else { return }
        settings.setCostAlertLimit(at: j, limit: value)
    case BR_ACT_RULE_DELETE:
        settings.removeRule(at: i)
    case BR_ACT_RULE_ADD:
        // The pane forwards the draft's provider, window and value, so add and
        // update are the same upsert — matching macOS's Add/Update button.
        guard let provider, let windowLabel else { return }
        let card = Int(index)
        settings.upsertDraft(kind: index, provider: String(cString: provider),
                             windowLabel: String(cString: windowLabel),
                             value: draft.value(for: card),
                             minutes: draft.minutes)
    case BR_ACT_WIDGET_TOGGLE:
        let names = (state.snapshot()?.usage.map(\.providerName) ?? []).sorted()
        guard i >= 0, i < names.count else { return }
        settings.setWidget(names[i], enabled: value != 0)
        syncWidgetTrays()
    case BR_ACT_DRAFT_PROVIDER:
        draft.provider = provider.map { String(cString: $0) } ?? ""
    case BR_ACT_DRAFT_WINDOW:
        draft.window = windowLabel.map { String(cString: $0) } ?? "Rolling"
    case BR_ACT_DRAFT_VALUE:
        draft.set(value, for: Int(index))
    case BR_ACT_CHECK_UPDATES:
        openReleases()
    default:
        return
    }
    presentSettingsPane()
}

@main
struct BurnRateLinuxMain {
    static func main() {
        // Tray is best-effort: without a session bus / watcher the app still runs.
        // A *symbolic* icon so the panel recolours it for light/dark — the Linux
        // equivalent of the macOS template status image, rather than a generic
        // theme icon that has nothing to do with the app.
        let tray = trayIconName.withCString { br_tray_add($0, "BurnRate", onTrayAction, nil) }
        state.setMainTray(tray)
        if tray >= 0 {
            state.setActionStore(ActionStore(), for: tray)
        }
        syncWidgetTrays()
        // The full-colour mark for the window, so the app does not fall back to
        // the desktop environment's default icon.
        let iconDir = installedIconDir()
        "burnrate".withCString { name in
            iconDir?.withCString { br_ui_set_icon(name, $0) } ?? br_ui_set_icon(name, nil)
        }
        br_ui_run("BurnRate", onQuery, onRefresh, nil)
        br_tray_stop_all()
    }
}
