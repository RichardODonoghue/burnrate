import Foundation

/// Caches the latest usage snapshot for all providers and notifies observers
/// after each poll.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var current: [ProviderUsage] = []

    func update(_ usage: [ProviderUsage]) {
        current = usage
    }

    func usage(for providerName: String) -> ProviderUsage? {
        current.first { $0.providerName == providerName }
    }
}
