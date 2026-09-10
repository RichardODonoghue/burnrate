import SwiftUI
import Charts

// MARK: - View model

/// One point of vendor-reported remaining-% history for a plan window.
struct RemainingSample: Codable, Equatable {
    let provider: String
    let label: String
    let date: Date
    let remaining: Double
}

@MainActor
final class ModelUsageViewModel: ObservableObject {
    @Published var daily: [DailyModelUsage] = []
    @Published var totals: [ModelUsageEntry] = []
    @Published var remainingHistory: [RemainingSample] = []
    @Published var loading = true

    private let sources: [(name: String, source: any UsageSource)]
    private let defaults: UserDefaults
    private static let historyKey = "modelUsageHistory"
    private static let remainingKey = "remainingHistory"
    private static let remainingRetention: TimeInterval = 7 * 86400

    init(sources: [(name: String, source: any UsageSource)], defaults: UserDefaults = .standard) {
        self.sources = sources
        self.defaults = defaults
        // Instant display from the last poll's persisted snapshot.
        if let data = defaults.data(forKey: Self.historyKey),
           let cached = try? JSONDecoder().decode([DailyModelUsage].self, from: data), !cached.isEmpty {
            daily = cached
            totals = ModelUsageAggregator.totals(fromCache: cached)
            loading = false
        }
        if let data = defaults.data(forKey: Self.remainingKey),
           let cached = try? JSONDecoder().decode([RemainingSample].self, from: data) {
            remainingHistory = cached
        }
    }

    /// Called after each poll with the vendor quota snapshot; appends to the
    /// remaining-% history that feeds the trend chart.
    func appendRemaining(snapshots: [ProviderUsage], date: Date = Date()) {
        let cutoff = date.addingTimeInterval(-Self.remainingRetention)
        for usage in snapshots {
            for window in usage.windows {
                guard let remaining = window.percentRemaining else { continue }
                remainingHistory.append(
                    RemainingSample(provider: usage.providerName,
                                    label: window.label,
                                    date: date,
                                    remaining: remaining)
                )
            }
        }
        remainingHistory = remainingHistory.filter { $0.date >= cutoff }
        if let data = try? JSONEncoder().encode(remainingHistory) {
            defaults.set(data, forKey: Self.remainingKey)
        }
    }

    func ingest(daily: [DailyModelUsage], totals: [ModelUsageEntry]) {
        self.daily = daily
        self.totals = totals
        loading = false
        if let data = try? JSONEncoder().encode(daily) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    func reload() {
        loading = daily.isEmpty
        Task {
            var buckets: [(provider: String, samples: [UsageSample])] = []
            for source in sources {
                let samples = (try? await source.source.collectSamples()) ?? []
                buckets.append((source.name, samples))
            }
            ingest(
                daily: ModelUsageAggregator.daily(buckets: buckets, days: 30),
                totals: ModelUsageAggregator.totals(buckets: buckets)
            )
        }
    }
}

private extension ModelUsageAggregator {
    /// Rebuild flat totals from cached daily buckets (for instant display).
    static func totals(fromCache daily: [DailyModelUsage]) -> [ModelUsageEntry] {
        var byKey: [String: ModelUsageEntry] = [:]
        for day in daily {
            for entry in day.entries {
                var merged = byKey[entry.id] ?? entry
                merged.tokens.input += entry.tokens.input
                merged.tokens.output += entry.tokens.output
                merged.tokens.cacheRead += entry.tokens.cacheRead
                merged.tokens.cacheWrite += entry.tokens.cacheWrite
                merged.cost += entry.cost
                merged.requests += entry.requests
                byKey[entry.id] = merged
            }
        }
        return byKey.values.sorted { $0.totalTokens > $1.totalTokens }
    }
}

// MARK: - Window root

struct ModelsView: View {
    @ObservedObject var viewModel: ModelUsageViewModel

    enum Range: String, CaseIterable, Identifiable {
        case today = "Today", week = "7d", month = "30d"
        var id: String { rawValue }
        var days: Int { self == .today ? 1 : (self == .week ? 7 : 30) }
    }
    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost"
        var id: String { rawValue }
    }
    @State private var range: Range = .week
    @State private var metric: Metric = .tokens
    @State private var providerFilter: String?
    @State private var trendWindow: String = "Rolling"

    /// Window labels actually present in history (for the selected provider
    /// filter). Claude reports Rolling/Weekly plus model-scoped weeklies
    /// (Fable); OpenCode Go reports Rolling/Weekly/Monthly. Scoped weeklies
    /// fold into Weekly (see canonicalTrendLabel), so they never appear as
    /// their own picker option.
    private var availableTrendLabels: [String] {
        let labels = Set(viewModel.remainingHistory
            .filter { providerFilter == nil || $0.provider == providerFilter }
            .map { canonicalTrendLabel($0.label) })
        guard !labels.isEmpty else { return ["Rolling", "Weekly", "Monthly"] }
        let preferred = ["Rolling", "Weekly", "Monthly"]
        return preferred.filter { labels.contains($0) } + labels.subtracting(preferred).sorted()
    }

    /// Model-scoped quotas (Fable today) come from weekly_scoped kinds, so
    /// they chart on the Weekly graph. The only exotic labels our sources can
    /// record are scoped weeklies — anything outside the three known windows
    /// belongs to Weekly.
    private func canonicalTrendLabel(_ label: String) -> String {
        switch label {
        case "Rolling", "Weekly", "Monthly": label
        default: "Weekly"
        }
    }

    /// Selected label if it has data, else the first available one (e.g.
    /// Monthly selected, then provider filtered to Claude-only).
    private var effectiveTrendLabel: String {
        availableTrendLabels.contains(trendWindow) ? trendWindow : availableTrendLabels[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if viewModel.loading && viewModel.daily.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Parsing local usage logs…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredDaily.isEmpty {
                ContentUnavailableView(
                    "No usage data",
                    systemImage: "chart.bar.doc.horizontal",
                    description: Text("Usage appears here once the local logs contain data.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        snapshotCards
                        trendChart
                        dailyChart
                        rankingChart
                        breakdownTable
                    }
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 700, minHeight: 480)
    }

    // MARK: Data selection

    private var providerNames: [String] {
        Array(Set(viewModel.totals.map(\.provider))).sorted()
    }

    private var filteredDaily: [DailyModelUsage] {
        viewModel.daily.filter {
            providerFilter == nil || $0.entries.contains { $0.provider == providerFilter }
        }
    }

    private func entries(for day: DailyModelUsage) -> [ModelUsageEntry] {
        day.entries.filter { providerFilter == nil || $0.provider == providerFilter }
    }

    private func metricValue(_ entry: ModelUsageEntry) -> Double {
        metric == .tokens ? Double(entry.totalTokens) : entry.cost
    }

    private var filteredTotals: [ModelUsageEntry] {
        viewModel.totals.filter { providerFilter == nil || $0.provider == providerFilter }
    }

    private var filteredRangeDaily: [DailyModelUsage] {
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-Double(range.days - 1) * 86400))
        return filteredDaily.filter { $0.day >= start }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("Usage Dashboard")
                .font(.headline)
            Spacer()
            Picker("Provider", selection: $providerFilter) {
                Text("All providers").tag(String?.none)
                ForEach(providerNames, id: \.self) { name in
                    Text(name).tag(String?.some(name))
                }
            }
            .frame(width: 180)
            Picker("Metric", selection: $metric) {
                ForEach(Metric.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            Picker("Range", selection: $range) {
                ForEach(Range.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            Button {
                viewModel.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Snapshot cards

    private var snapshotCards: some View {
        HStack(spacing: 12) {
            rollingCard
            tokensTodayCard
            costTodayCard
        }
    }

    /// Latest vendor-reported Rolling remaining % per provider.
    private var latestRolling: [(provider: String, remaining: Double)] {
        var latest: [String: (date: Date, remaining: Double)] = [:]
        for sample in viewModel.remainingHistory where sample.label == "Rolling" {
            if let current = latest[sample.provider] {
                if sample.date > current.date { latest[sample.provider] = (sample.date, sample.remaining) }
            } else {
                latest[sample.provider] = (sample.date, sample.remaining)
            }
        }
        return latest.map { (provider: $0.key, remaining: $0.value.remaining) }
            .sorted { $0.remaining < $1.remaining }
    }

    private var todayEntries: [ModelUsageEntry] {
        let start = Calendar.current.startOfDay(for: Date())
        return viewModel.daily.first { $0.day >= start }?.entries ?? []
    }

    private var rollingCard: some View {
        card(title: "Rolling usage", icon: "gauge.with.needle") {
            let latest = latestRolling
            if latest.isEmpty {
                Text("Collecting…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(latest, id: \.provider) { item in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(SettingsView.color(for: item.provider))
                                .frame(width: 7, height: 7)
                            Text(item.provider)
                            Spacer()
                            Text("\(Int(item.remaining))%")
                                .monospacedDigit()
                                .fontWeight(.semibold)
                        }
                    }
                }
            }
        }
    }

    private var tokensTodayCard: some View {
        card(title: "Tokens today", icon: "number") {
            let entries = todayEntries
            let total = entries.reduce(0) { $0 + $1.totalTokens }
            let requests = entries.reduce(0) { $0 + $1.requests }
            VStack(alignment: .leading, spacing: 4) {
                Text(total == 0 ? "—" : StatusItemManager.formatTokens(total))
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("\(requests) requests")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var costTodayCard: some View {
        card(title: "Cost today", icon: "dollarsign.circle") {
            let cost = todayEntries.reduce(0.0) { $0 + $1.cost }
            VStack(alignment: .leading, spacing: 4) {
                Text(cost > 0 ? String(format: "$%.2f", cost) : "—")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Text("list-price estimate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func card<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .foregroundStyle(.orange)
                    Text(title)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Charts

    /// Vendor-reported remaining-% over time, one line per provider.
    private var trendChart: some View {
        GroupBox {
            HStack {
                Text("Remaining over time — \(effectiveTrendLabel)")
                    .font(.headline)
                Spacer()
                Picker("Window", selection: $trendWindow) {
                    ForEach(availableTrendLabels, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: CGFloat(max(availableTrendLabels.count, 3)) * 86)
            }
            let series = trendSeries
            if series.isEmpty {
                emptyHint("Collecting history… this chart fills in as BurnRate polls (a point every 5 minutes).")
                    .frame(height: 140)
            } else {
                Chart {
                    ForEach(trendSeries, id: \.key) { series in
                        ForEach(series.samples, id: \.date) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Remaining", point.remaining)
                            )
                            .foregroundStyle(by: .value("Series", series.name))
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   dash: series.scoped ? [6, 4] : []))
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis {
                    // Rolling covers ~days: tick every 6 hours. Longer
                    // windows (Weekly/Monthly/Fable) get one tick per day.
                    if effectiveTrendLabel == "Rolling" {
                        AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    } else {
                        AxisMarks(values: .stride(by: .day)) { value in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let remaining = value.as(Double.self) {
                                Text("\(Int(remaining))%")
                            }
                        }
                    }
                }
                // By-value coloring + automatic legend: one entry per series,
                // colors matched to the provider (scoped weeklies faded).
                .chartLegend(position: .bottom)
                .chartForegroundStyleScale(
                    domain: trendSeries.map(\.name),
                    range: trendSeries.map {
                        SettingsView.color(for: $0.provider).opacity($0.scoped ? 0.55 : 1)
                    }
                )
                .frame(height: 180)
            }
        }
    }

    /// Per-provider series for the selected window. A provider can contribute
    /// several lines (Claude Weekly + Claude Fable): the main window keeps
    /// the provider color, scoped weeklies draw dashed and faded.
    private var trendSeries: [(key: String, name: String, provider: String, scoped: Bool,
                               samples: [(date: Date, remaining: Double)])] {
        let filtered = viewModel.remainingHistory.filter {
            canonicalTrendLabel($0.label) == effectiveTrendLabel
                && (providerFilter == nil || $0.provider == providerFilter)
        }
        let dict = Dictionary(grouping: filtered, by: { "\($0.provider)|\($0.label)" })
        return dict.keys.sorted().map { key in
            let points = dict[key]!.sorted { $0.date < $1.date }
            let provider = points[0].provider
            let label = points[0].label
            let scoped = label != effectiveTrendLabel
            let name = scoped ? "\(provider) \(label)" : provider
            return (key, name, provider, scoped,
                    points.map { (date: $0.date, remaining: $0.remaining) })
        }
    }
    }

    private func emptyHint(_ text: String) -> some View {
        Label(text, systemImage: "waveform.path")
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    private var dailyChart: some View {
        GroupBox("Daily usage by model (\(metric.rawValue))") {
            Chart {
                ForEach(filteredRangeDaily, id: \.day) { day in
                    ForEach(entries(for: day)) { entry in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value(metric.rawValue, metricValue(entry))
                        )
                        .foregroundStyle(byModel(entry.model))
                        .cornerRadius(2)
                    }
                }
            }
            .chartLegend(position: .bottom) {
                modelLegend
            }
            .frame(height: 220)
        }
        
    }

    private var rankingChart: some View {
        GroupBox("Top models (\(range.rawValue))") {
            Chart(filteredTotals.prefix(8)) { entry in
                BarMark(
                    x: .value(metric.rawValue, metricValue(entry)),
                    y: .value("Model", entry.model)
                )
                .foregroundStyle(byModel(entry.model))
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text(annotation(entry))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis(metric == .tokens ? .visible : .hidden)
            .frame(height: CGFloat(min(filteredTotals.count, 8)) * 34 + 10)
        }
        
    }

    private func annotation(_ entry: ModelUsageEntry) -> String {
        metric == .tokens
            ? StatusItemManager.formatTokens(entry.totalTokens) + " tok"
            : String(format: "$%.2f", entry.cost)
    }

    private var modelLegend: some View {
        let models = Array(Set(filteredRangeDaily.flatMap { entries(for: $0).map(\.model) })).sorted()
        return HStack(spacing: 12) {
            ForEach(models, id: \.self) { model in
                HStack(spacing: 4) {
                    Circle().fill(byModel(model)).frame(width: 7, height: 7)
                    Text(model).font(.caption2)
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Breakdown table

    private var breakdownTable: some View {
        GroupBox("Breakdown (\(range.rawValue))") {
            VStack(spacing: 0) {
                HStack {
                    Text("MODEL").frame(maxWidth: .infinity, alignment: .leading)
                    columnHeader("INPUT")
                    columnHeader("OUTPUT")
                    columnHeader("CACHE")
                    columnHeader("REQUESTS")
                    columnHeader("TOKENS")
                    columnHeader("COST")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 6)
                ForEach(filteredTotals) { entry in
                    HStack {
                        HStack(spacing: 6) {
                            Circle().fill(byModel(entry.model)).frame(width: 7, height: 7)
                            Text(entry.model)
                            Text(entry.provider)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(StatusItemManager.formatTokens(entry.tokens.input))
                        cell(StatusItemManager.formatTokens(entry.tokens.output))
                        cell(StatusItemManager.formatTokens(entry.tokens.cacheRead + entry.tokens.cacheWrite))
                        cell("\(entry.requests)")
                        cell(StatusItemManager.formatTokens(entry.totalTokens), bold: true)
                        cell(entry.cost > 0 ? String(format: "$%.2f", entry.cost) : "—", bold: true)
                    }
                    .font(.callout)
                    .monospacedDigit()
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        
    }

    private func columnHeader(_ title: String) -> some View {
        Text(title)
            .frame(width: 80, alignment: .trailing)
    }

    private func cell(_ text: String, bold: Bool = false) -> some View {
        Text(text)
            .fontWeight(bold ? .semibold : .regular)
            .frame(width: 80, alignment: .trailing)
    }

    // MARK: Colors

    private func byModel(_ model: String) -> Color {
        Self.palette[abs(model.hashValue) % Self.palette.count]
    }

    private static let palette: [Color] = [
        Color(red: 0.85, green: 0.47, blue: 0.34),
        Color(red: 0.25, green: 0.55, blue: 0.95),
        Color(red: 0.20, green: 0.68, blue: 0.44),
        Color(red: 0.72, green: 0.45, blue: 0.85),
        Color(red: 0.95, green: 0.62, blue: 0.24),
        Color(red: 0.30, green: 0.72, blue: 0.78),
        Color(red: 0.83, green: 0.36, blue: 0.55),
        Color(red: 0.55, green: 0.60, blue: 0.35),
    ]
}
