import Foundation

/// Fixed token capacities (weighted: cache read ×0.1, write ×1.25) for
/// local-log providers, keyed "provider|windowLabel". Codex is the only
/// provider measured from logs; the quota APIs report their own %.
public enum PlanCapacities {
    public static let byProviderWindow: [String: Int] = [
        "Codex|Rolling": 12_000_000,
        "Codex|Weekly": 120_000_000,
        "Codex|Monthly": 400_000_000,
    ]
}
