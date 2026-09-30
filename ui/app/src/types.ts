// The wire shapes, as Rust sends them.
//
// Every field here is `#[serde(rename_all = "camelCase")]` on the Rust side, so
// these are the *wire* names, not the Rust names. Two bugs came from getting that
// wrong: `dashboard.rangeLabel` was read before the field existed (both charts
// titled "Top models (undefined)"), and `providerName` was read as
// `provider_name`, which found nothing and fell through a fallback that happened
// to look right.
//
// Generated bindings replace this file once specta is wired up; until then it is
// the one place the contract is written down, so a mismatch is a compile error at
// every use rather than a runtime `undefined`.

/** The panes the window can show. */
export type AppPane = "usage" | "notifications" | "widgets" | "about";

/** Chart ranges, as `ChartRange` serialises them. */
export type ChartRange = "today" | "week" | "month";

/** Tokens or cost, as `Metric` serialises it (lowercase). */
export type Metric = "tokens" | "cost";

export interface TokenUsage {
  input: number;
  output: number;
  cacheRead: number;
  cacheWrite: number;
  reasoning: number;
}

export interface UsageWindow {
  id: string;
  label: string;
  tokensUsed: number;
  /** `null` when no plan capacity is configured for this window. */
  percentRemaining: number | null;
  resetsAt: number | null;
}

export interface ProviderUsage {
  providerName: string;
  plan: string | null;
  windows: UsageWindow[];
}

export interface Milestone {
  provider: string;
  windowLabel: string;
  /** Percentage points, e.g. 10 = notify at 90/80/70… remaining. */
  step: number;
}

export interface BurnAlert {
  provider: string;
  windowLabel: string;
  percentDrop: number;
  minutes: number;
}

export interface CostAlert {
  provider: string;
  dailyLimitUsd: number;
}

export interface Settings {
  milestones: Milestone[];
  widgetProviders: string[];
  burnAlerts: BurnAlert[];
  costAlerts: CostAlert[];
  notifyOnReset: boolean;
  pollIntervalSeconds: number;
}

/** A labelled figure in a snapshot card. */
export interface Figure {
  key: string;
  label: string;
  value: string;
}

/** One point on the trend chart, already in data space. */
export interface Point {
  x: number;
  y: number;
}

export interface Series {
  key: string;
  name: string;
  provider: string;
  /** Model-scoped windows (Claude's Fable) draw dashed and faded. */
  scoped: boolean;
  points: Point[];
}

/** A gridline or tick label on either axis. */
export interface Tick {
  at: number;
  label: string;
}

/** One row of the ranking chart or the breakdown table. */
export interface Bar {
  key: string;
  provider: string;
  label: string;
  value: number;
  cost: number;
  tokens: number;
  input: number;
  output: number;
  cache: number;
  reasoning: number;
  requests: number;
  /** `axisLabel(value, metric)`, pre-formatted in Rust. */
  valueText: string;
  /** The ranking chart's trailing annotation: "1.2m tok" or "$12.50". */
  annotation: string;
}

export interface DailyBar {
  day: number;
  total: number;
  totalText: string;
  bars: Bar[];
  /** Today, or the last day in range: drawn faded, because a part-day beside
   *  complete days reads as a cliff. */
  partial: boolean;
}

export interface Dashboard {
  range: ChartRange;
  rangeLabel: string;
  metric: Metric;
  metricLabel: string;
  windowLabel: string;
  providerFilter: string | null;
  windowLabels: string[];
  providerNames: string[];

  rolling: Figure[];
  tokensToday: number | null;
  requestsToday: number;
  costToday: number;

  series: Series[];
  xDomain: [number, number];
  xStyle: string;
  xTicks: Tick[];
  yDomain: [number, number];
  yTicks: number[];

  daily: DailyBar[];
  dailyYTicks: number[];
  dailyYLabels: string[];
  dailyMaximum: number;
  hasData: boolean;

  ranking: Bar[];
  rankingTicks: number[];
  rankingTickLabels: string[];
  table: Bar[];
  /** Models with no entry in the price table, so the COST column can say why. */
  unpricedModels: string[];
}

export interface PlatformInfo {
  os: string;
  runtimeDependencies: string[];
}

/** Everything the window renders from, in one payload. */
export interface Snapshot {
  pane: AppPane;
  settings: Settings;
  usage: ProviderUsage[];
  missing: string[];
  remaining: number | null;
  appVersion: string;
  coreVersion: string;
  lastPollUnix: number;
  pollCount: number;
  platforms: PlatformInfo;
  dashboard: Dashboard;
  spendToday: Record<string, number>;
}

/** `Bar` is used for both the ranking chart and the table. */
export type RankingBar = Bar;

/** The chart a plot frame draws. */
export type ChartKind = "trend" | "daily" | "ranking";

/** A projector maps a data value to a pixel. */
export interface Projector {
  x(value: number): number;
  y(value: number): number;
  left: number;
  right: number;
  top: number;
  bottom: number;
  plotWidth: number;
  plotHeight: number;
}

export interface Padding {
  top: number;
  right: number;
  bottom: number;
  left: number;
}
