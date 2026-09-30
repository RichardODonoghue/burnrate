// Small pure formatters.
//
// Deliberately tiny: the numbers that matter — axis labels, annotations, day
// totals — arrive pre-formatted from Rust, because the frontend formatting its own
// copy is exactly how the axes drifted from the Swift build. What is left here is
// display-only.

/** Compact token counts: 850, 42.3k, 1.2m, 3.6b, 1.1t. Mirrors `TokenFormat`. */
export function tokenCount(value: number): string {
  const units: [number, string][] = [
    [1e12, "t"],
    [1e9, "b"],
    [1e6, "m"],
    [1e3, "k"],
  ];
  for (const [size, suffix] of units) {
    if (value >= size) return `${trim(value / size)}${suffix}`;
  }
  return String(value);
}

/** Two decimals, trailing zeros dropped: 10.0 → "10", 1.25 → "1.25". */
export function trim(value: number): string {
  return value.toFixed(2).replace(/\.?0+$/, "");
}

/** "in 45m" / "in 4h 20m" / "in 3d", matching `RelativeTime`. */
export function relativeTime(resetsAtUnix: number | null): string {
  if (!resetsAtUnix) return "";
  const seconds = resetsAtUnix - Math.floor(Date.now() / 1000);
  if (seconds <= 0) return "now";
  if (seconds < 3600) return `in ${Math.ceil(seconds / 60)}m`;
  if (seconds < 86_400) {
    const hours = Math.floor(seconds / 3600);
    const minutes = Math.floor((seconds % 3600) / 60);
    return minutes > 0 ? `in ${hours}h ${minutes}m` : `in ${hours}h`;
  }
  return `in ${Math.ceil(seconds / 86_400)}d`;
}

/** The severity ramp's colour for a remaining percentage. */
export function severityColour(remaining: number | null | undefined): string {
  if (remaining === null || remaining === undefined) return "var(--fg-muted)";
  if (remaining >= 55) return "rgb(143, 224, 122)";
  if (remaining >= 45) return "rgb(255, 194, 75)";
  if (remaining >= 20) return "rgb(255, 138, 92)";
  return "rgb(230, 64, 25)";
}

/**
 * A day bucket's date.
 *
 * `day` is the epoch of *local* midnight, so the local fields of that instant are
 * the day — reading UTC fields instead would show yesterday for anyone east of
 * Greenwich.
 */
export function dayLabel(day: number): string {
  return new Date(day * 1000).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

/** A day bucket's date with its weekday, for the daily tooltip header. */
export function dayHeading(day: number): string {
  return new Date(day * 1000).toLocaleDateString(undefined, {
    weekday: "short",
    month: "short",
    day: "numeric",
  });
}
