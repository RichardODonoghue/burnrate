import BurnRateCore
import SwiftUI
import Charts

// MARK: - View model

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

    // Derived-data caches. Rebuilding these walks the full remaining history
    // (thousands of samples) and the daily buckets, and hover changes re-render
    // the dashboard constantly — so cache until the underlying data changes.
    private var trendCache: (key: String, series: [TrendSeries])?
    private var labelCache: (key: String, labels: [String])?
    private var rangeDailyCache: (key: String, days: [DailyModelUsage])?

    private func invalidateDerivedCaches() {
        trendCache = nil
        labelCache = nil
        rangeDailyCache = nil
    }

    init(sources: [(name: String, source: any UsageSource)], defaults: UserDefaults = .standard) {
        self.sources = sources
        self.defaults = defaults
        // Instant display from the last poll's persisted snapshot. Synthetic
        // placeholder rows from older builds are scrubbed here too — the UI
        // must never show them, even before the next poll rewrites the cache.
        if let data = defaults.data(forKey: Self.historyKey),
           let cached = try? JSONDecoder().decode([DailyModelUsage].self, from: data),
           !cached.isEmpty {
            daily = cached
                .map { DailyModelUsage(day: $0.day,
                                       entries: $0.entries.filter { ModelUsageAggregator.isDisplayable(model: $0.model) }) }
                .filter { !$0.entries.isEmpty }
            totals = ModelUsageAggregator.totals(fromDaily: daily)
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
        invalidateDerivedCaches()
        if let data = try? JSONEncoder().encode(remainingHistory) {
            defaults.set(data, forKey: Self.remainingKey)
        }
    }

    func ingest(daily: [DailyModelUsage], totals: [ModelUsageEntry]) {
        self.daily = daily
        self.totals = totals
        loading = false
        invalidateDerivedCaches()
        if let data = try? JSONEncoder().encode(daily) {
            defaults.set(data, forKey: Self.historyKey)
        }
    }

    /// Provider-filtered trend series for a window, over the range's trailing
    /// span. Cached until new data arrives.
    func trendSeries(label: String, providerFilter: String?, range: ChartRange) -> [TrendSeries] {
        let key = "\(label)|\(providerFilter ?? "*")|\(range.span)"
        if let trendCache, trendCache.key == key { return trendCache.series }
        let series = TrendChartData.buildTrendSeries(
            samples: remainingHistory,
            label: label,
            providerFilter: providerFilter,
            cutoff: Date().addingTimeInterval(-range.span)
        )
        trendCache = (key, series)
        return series
    }

    /// Window labels present in the range, for the window picker. Cached.
    func trendLabels(providerFilter: String?, range: ChartRange) -> [String] {
        let key = "\(providerFilter ?? "*")|\(range.span)"
        if let labelCache, labelCache.key == key { return labelCache.labels }
        let cutoff = Date().addingTimeInterval(-range.span)
        let present = Set(remainingHistory
            .filter { (providerFilter == nil || $0.provider == providerFilter) && $0.date >= cutoff }
            .map { TrendChartData.canonicalTrendLabel($0.label) })
        let preferred = ["Rolling", "Weekly", "Monthly"]
        let labels = present.isEmpty
            ? preferred
            : preferred.filter { present.contains($0) } + present.subtracting(preferred).sorted()
        labelCache = (key, labels)
        return labels
    }

    /// Daily buckets overlapping the range's trailing span, with each day's
    /// entries filtered to the provider. Cached until new data arrives.
    func rangeDaily(range: ChartRange, providerFilter: String?) -> [DailyModelUsage] {
        let key = "\(providerFilter ?? "*")|\(range.span)"
        if let rangeDailyCache, rangeDailyCache.key == key { return rangeDailyCache.days }
        let start = Calendar.current.startOfDay(for: Date().addingTimeInterval(-range.span))
        let days = daily.filter { $0.day >= start }.compactMap { day -> DailyModelUsage? in
            let entries = providerFilter == nil
                ? day.entries
                : day.entries.filter { $0.provider == providerFilter }
            return entries.isEmpty ? nil : DailyModelUsage(day: day.day, entries: entries)
        }
        rangeDailyCache = (key, days)
        return days
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

// MARK: - Window root

struct ModelsView: View {
    @ObservedObject var viewModel: ModelUsageViewModel

    enum Metric: String, CaseIterable, Identifiable {
        case tokens = "Tokens", cost = "Cost"
        var id: String { rawValue }
    }
    @State private var range: ChartRange = .week
    @State private var metric: Metric = .tokens
    @State private var providerFilter: String?
    @State private var trendWindow: String = "Rolling"
    @State private var selectedDate: Date?
    /// Hovered day in the daily chart / hovered model in the ranking chart.
    @State private var selectedDay: Date?
    @State private var selectedModel: String?

    private var rangeCutoff: Date {
        TrendChartData.trendCutoff(for: range, now: Date())
    }

    /// Selected label if it has data, else the first available one (e.g.
    /// Monthly selected, then provider filtered to Claude-only).
    private var effectiveTrendLabel: String {
        availableTrendLabels.contains(trendWindow) ? trendWindow : availableTrendLabels[0]
    }

    /// Window labels actually present in the range, for the picker. Claude
    /// adds model-scoped weeklies (Fable); those fold into Weekly (see
    /// canonicalTrendLabel), so they never become their own picker option.
    private var availableTrendLabels: [String] {
        viewModel.trendLabels(providerFilter: providerFilter, range: range)
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
                CardPane {
                    snapshotCards
                    trendChart
                    dailyChart
                    rankingChart
                    breakdownTable
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
        // Aggregate from the in-range buckets: viewModel.totals spans the full
        // 30 days and would leak out-of-range models into narrow ranges.
        ModelUsageAggregator.totals(fromDaily: filteredRangeDaily)
    }

    /// Daily buckets overlapping the trailing range, entries already filtered
    /// to the selected provider. Cached in the view model.
    private var filteredRangeDaily: [DailyModelUsage] {
        viewModel.rangeDaily(range: range, providerFilter: providerFilter)
    }


    private var trendDayTicks: [Date] {
        let domain = trendXDomain
        return TrendChartData.trendTickDates(cutoff: domain.lowerBound, now: domain.upperBound)
    }

    private var trendXDomain: ClosedRange<Date> {
        TrendChartData.trendXDomain(series: trendSeries, cutoff: rangeCutoff, now: Date())
    }

    private func trendTooltip(for date: Date) -> some View {
        tooltipCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(TrendChartData.nearestRows(series: trendSeries, at: date), id: \.name) { row in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SettingsView.color(for: row.provider).opacity(row.scoped ? 0.55 : 1))
                            .frame(width: 7, height: 7)
                        Text(row.name)
                        Spacer(minLength: 12)
                        Text("\(Int(row.remaining))%")
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
            }
        }
    }

    /// Shared tooltip chrome: floating card with a hairline border + shadow.
    private func tooltipCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .shadow(radius: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            )
            .fixedSize()
    }

    /// Tokens/cost for one entry, as shown on axes and in tooltips.
    private func metricText(_ entry: ModelUsageEntry) -> String {
        metric == .tokens
            ? TokenFormat.format(entry.totalTokens)
            : String(format: "$%.2f", entry.cost)
    }

    private func dailyTooltip(for day: DailyModelUsage) -> some View {
        let rows = day.entries.filter { metricValue($0) > 0 }
        return tooltipCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(rows) { entry in
                    HStack(spacing: 6) {
                        Circle().fill(byModel(entry.displayName)).frame(width: 7, height: 7)
                        Text(entry.displayName)
                        Spacer(minLength: 12)
                        Text(metricText(entry))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
                if rows.count > 1 {
                    Divider()
                    HStack(spacing: 6) {
                        Text("Total")
                        Spacer(minLength: 12)
                        Text(metric == .tokens
                             ? TokenFormat.format(rows.reduce(0) { $0 + $1.totalTokens })
                             : String(format: "$%.2f", rows.reduce(0) { $0 + $1.cost }))
                            .monospacedDigit()
                            .fontWeight(.semibold)
                    }
                    .font(.caption)
                }
            }
        }
    }

    private func modelTooltip(for entry: ModelUsageEntry) -> some View {
        tooltipCard {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(byModel(entry.displayName)).frame(width: 7, height: 7)
                    Text(entry.displayName)
                        .fontWeight(.semibold)
                }
                .font(.caption)
                Text(entry.provider)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text("\(metric == .tokens ? "Tokens" : "Cost")")
                    Spacer(minLength: 12)
                    Text(metricText(entry))
                        .monospacedDigit()
                        .fontWeight(.semibold)
                }
                .font(.caption)
                HStack(spacing: 6) {
                    Text("Requests")
                    Spacer(minLength: 12)
                    Text("\(entry.requests)")
                        .monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if entry.tokens.reasoning > 0 {
                    HStack(spacing: 6) {
                        Text("Reasoning")
                        Spacer(minLength: 12)
                        Text(TokenFormat.format(entry.tokens.reasoning))
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Compact Y-axis labels — Charts defaults to scientific notation for
    /// large token counts (e.g. 2.5e+06). Tokens shorten k/m/b/t, cost as $.
    nonisolated static func axisLabel(_ value: Double, metric: Metric) -> String {
        if metric == .cost {
            return abs(value) < 1000
                ? String(format: "$%g", value)
                : "$" + TokenFormat.format(Int(value))
        }
        return TokenFormat.format(Int(value))
    }

    /// Auto-scaled Y domain for the trend chart: spans the visible data plus
    /// padding so lines aren't flattened when the range is narrow, clamped to
    /// 0…100 elsewhere. Empty series → full domain.
    private var remainingDomain: ClosedRange<Double> {
        TrendChartData.remainingDomain(trendSeries)
    }

    private var trendYTicks: [Double] {
        TrendChartData.yTicks(in: remainingDomain)
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
                ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
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

    private var latestRolling: [(provider: String, remaining: Double)] {
        TrendChartData.latestRolling(samples: viewModel.remainingHistory, providerFilter: providerFilter)
    }

    /// Today's entries for the cards, honoring the provider filter.
    private var todayEntries: [ModelUsageEntry] {
        guard let day = TrendChartData.dayBucket(for: Date(), in: viewModel.daily) else { return [] }
        return entries(for: day)
    }

    private var rollingCard: some View {
        Card("Rolling usage", icon: "gauge.with.needle", subtleTitle: true) {
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
        Card("Tokens today", icon: "number", subtleTitle: true) {
            let entries = todayEntries
            let total = entries.reduce(0) { $0 + $1.totalTokens }
            let requests = entries.reduce(0) { $0 + $1.requests }
            VStack(alignment: .leading, spacing: 4) {
                Text(total == 0 ? "—" : TokenFormat.format(total))
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
        Card("Cost today", icon: "dollarsign.circle", subtleTitle: true) {
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

    // MARK: Charts

    /// Vendor-reported remaining-% over time, one line per provider.
    private var trendChart: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
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
            // Claude's quota has no monthly window (only 5-hour and weekly),
            // so a Monthly view that looks sparse is expected, not a gap.
            if effectiveTrendLabel == "Monthly" {
                Label("Claude has no monthly limit — its windows are 5-hour and weekly.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                            // Monotone, not catmullRom: a spline through a
                            // sharp reset overshoots past the data (below 0%
                            // / above 100%), and Charts doesn't clip marks to
                            // the plot, so the line escaped the graph.
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round,
                                                   dash: series.scoped ? [6, 4] : []))
                        }
                    }
                    if let selectedDate {
                        RuleMark(x: .value("Selected", selectedDate))
                            .foregroundStyle(.secondary.opacity(0.4))
                    }
                }
                .chartXSelection(value: $selectedDate)
                // Tooltip as an overlay, not an annotation: an annotation
                // re-lays-out the chart (pushing the plot sideways) and
                // clips past the plot's top edge.
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let selectedDate,
                           let x = proxy.position(forX: selectedDate),
                           let plot = proxy.plotFrame {
                            let plotFrame = geometry[plot]
                            PlotTooltip(anchor: CGPoint(x: plotFrame.minX + x,
                                                        y: plotFrame.minY + 44),
                                        plotFrame: plotFrame) {
                                trendTooltip(for: selectedDate)
                            }
                        }
                    }
                }
                // Plot-dimension padding keeps data at exactly 0%/100% off
                // the plot edge — flush marks are half-clipped by the frame
                // and look like the line leaves the graph.
                .chartYScale(domain: remainingDomain,
                             range: .plotDimension(startPadding: 6, endPadding: 6))
                .chartXScale(domain: trendXDomain)
                .chartXAxis {
                    // Ticks follow the visible span — scaled down to a few
                    // hours, hourly marks; multi-day spans label midnight
                    // (weekday) plus noon (12pm) each day.
                    let domain = trendXDomain
                    let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
                    if TrendChartData.trendXHourly(span: span) {
                        AxisMarks(values: .stride(by: .hour,
                                                  count: TrendChartData.trendHourStride(span: span))) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    } else {
                        AxisMarks(values: trendDayTicks) { value in
                            AxisGridLine()
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(TrendChartData.trendTickLabel(date))
                                }
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: trendYTicks) { value in
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
    }

    private var trendSeries: [TrendSeries] {
        viewModel.trendSeries(label: effectiveTrendLabel,
                             providerFilter: providerFilter,
                             range: range)
    }

    private func emptyHint(_ text: String) -> some View {
        Label(text, systemImage: "waveform.path")
            .foregroundStyle(.secondary)
            .font(.callout)
    }

    private var dailyChart: some View {
        Card("Daily usage by model (\(metric.rawValue))") {
            VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(filteredRangeDaily, id: \.day) { day in
                    ForEach(day.entries) { entry in
                        BarMark(
                            x: .value("Day", day.day, unit: .day),
                            y: .value(metric.rawValue, metricValue(entry))
                        )
                        // Data-driven color (not a fixed color): this is what
                        // makes Charts generate the legend key automatically.
                        .foregroundStyle(by: .value("Model", entry.displayName))
                        .cornerRadius(2)
                    }
                }
            }
            .chartXSelection(value: $selectedDay)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let selectedDay,
                       let day = TrendChartData.dayBucket(for: selectedDay, in: filteredRangeDaily),
                       let x = proxy.position(forX: day.day),
                       let plot = proxy.plotFrame {
                        let plotFrame = geometry[plot]
                        PlotTooltip(anchor: CGPoint(x: plotFrame.minX + x,
                                                    y: plotFrame.minY + 44),
                                    plotFrame: plotFrame) {
                            dailyTooltip(for: day)
                        }
                    }
                }
            }
            .chartLegend(.hidden)
            .chartForegroundStyleScale(
                domain: legendModels,
                range: legendModels.map(byModel)
            )
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(Self.axisLabel(v, metric: metric))
                        }
                    }
                }
            }
            .frame(height: 220)
            // Own wrapping legend instead of the automatic one: long model
            // names (local MLX models especially) overflowed the card and
            // became unreadable.
            if !legendModels.isEmpty {
                modelLegend(legendModels)
            }
            }
        }
    }

    /// Wrapping legend for the daily chart: fixed-width columns, middle
    /// truncation, full name on hover.
    private func modelLegend(_ models: [String]) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 6
        ) {
            ForEach(models, id: \.self) { model in
                HStack(spacing: 5) {
                    Circle()
                        .fill(byModel(model))
                        .frame(width: 8, height: 8)
                    Text(model)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .help(model)
            }
        }
    }

    private var rankingChart: some View {
        Card("Top models (\(range.rawValue))") {
            VStack(alignment: .leading, spacing: 12) {
            Chart(filteredTotals.prefix(8)) { entry in
                BarMark(
                    x: .value(metric.rawValue, metricValue(entry)),
                    y: .value("Model", entry.displayName)
                )
                .foregroundStyle(byModel(entry.displayName))
                .cornerRadius(3)
                .annotation(position: .trailing) {
                    Text(annotation(entry))
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .chartXAxis {
                if metric == .tokens {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) {
                                Text(Self.axisLabel(v, metric: metric))
                            }
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    // Hover tracking: the horizontal bar's category is the
                    // model, so resolve the cursor's Y to a model name.
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                selectedModel = proxy.value(atY: location.y, as: String.self)
                            case .ended:
                                selectedModel = nil
                            }
                        }
                    if let selectedModel,
                       let entry = filteredTotals.first(where: { $0.displayName == selectedModel }),
                       let y = proxy.position(forY: selectedModel),
                       let plot = proxy.plotFrame {
                        let plotFrame = geometry[plot]
                        PlotTooltip(anchor: CGPoint(x: plotFrame.maxX,
                                                    y: plotFrame.minY + y),
                                    plotFrame: plotFrame) {
                            modelTooltip(for: entry)
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(filteredTotals.count, 8)) * 34 + 10)
            }
        }
    }

    private func annotation(_ entry: ModelUsageEntry) -> String {
        metric == .tokens
            ? TokenFormat.format(entry.totalTokens) + " tok"
            : String(format: "$%.2f", entry.cost)
    }

    /// Models visible in the daily chart, in stable order — the legend domain.
    private var legendModels: [String] {
        Array(Set(filteredRangeDaily.flatMap { $0.entries.map(\.displayName) })).sorted()
    }

    // MARK: Breakdown table

    private var breakdownTable: some View {
        Card("Breakdown (\(range.rawValue))") {
            VStack(alignment: .leading, spacing: 12) {
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
                            Circle().fill(byModel(entry.displayName)).frame(width: 7, height: 7)
                            Text(entry.displayName)
                            Text(entry.provider)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        cell(TokenFormat.format(entry.tokens.input))
                        cell(TokenFormat.format(entry.tokens.output))
                        cell(TokenFormat.format(entry.tokens.cacheRead + entry.tokens.cacheWrite))
                        cell("\(entry.requests)")
                        cell(TokenFormat.format(entry.totalTokens), bold: true)
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

// MARK: - Tooltip overlay

/// Floating tooltip card positioned at an anchor, clamped so it stays fully
/// inside the plot area — centring on the anchor clips at the chart edges.
private struct PlotTooltip<Content: View>: View {
    let anchor: CGPoint
    let plotFrame: CGRect
    let content: Content

    @State private var size: CGSize = .zero

    init(anchor: CGPoint, plotFrame: CGRect, @ViewBuilder content: () -> Content) {
        self.anchor = anchor
        self.plotFrame = plotFrame
        self.content = content()
    }

    var body: some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            // Never intercept the hover that drives the tooltip.
            .allowsHitTesting(false)
            .position(x: clampedX, y: clampedY)
    }

    private var clampedX: CGFloat {
        guard plotFrame.width > size.width else { return plotFrame.midX }
        return min(max(anchor.x, plotFrame.minX + size.width / 2),
                   plotFrame.maxX - size.width / 2)
    }

    private var clampedY: CGFloat {
        guard plotFrame.height > size.height else { return plotFrame.midY }
        return min(max(anchor.y, plotFrame.minY + size.height / 2),
                   plotFrame.maxY - size.height / 2)
    }
}
