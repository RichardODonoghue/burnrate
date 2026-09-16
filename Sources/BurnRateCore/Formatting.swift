import Foundation

/// Compact token counts: 850, 42.3k, 1.2m, 3.6b, 1.1t.
public enum TokenFormat {
    public static func format(_ count: Int) -> String {
        let value = Double(count)
        switch value {
        case ..<1_000: return "\(count)"
        case ..<1_000_000: return trim(value / 1_000) + "k"
        case ..<1_000_000_000: return trim(value / 1_000_000) + "m"
        case ..<1_000_000_000_000: return trim(value / 1_000_000_000) + "b"
        default: return trim(value / 1_000_000_000_000) + "t"
        }
    }

    /// Trims trailing zeros: 10.0 → "10", 1.5 → "1.5", 1.25 → "1.25".
    private static func trim(_ value: Double) -> String {
        let string = String(format: "%.2f", value)
        return string
            .replacingOccurrences(of: #"(\.\d*?)0+$"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

/// Compact relative time: "in 45m", "in 5h", "in 3d" (or "now"). Keeps menu
/// rows narrow — a full date was the widest line in the dropdown.
public enum RelativeTime {
    public static func format(_ date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        if seconds < 3600 { return "in \(Int((seconds / 60).rounded(.up)))m" }
        if seconds < 86_400 {
            let hours = Int(seconds / 3600)
            let minutes = Int(seconds.truncatingRemainder(dividingBy: 3600) / 60)
            return minutes > 0 ? "in \(hours)h \(minutes)m" : "in \(hours)h"
        }
        return "in \(Int((seconds / 86_400).rounded(.up)))d"
    }
}
