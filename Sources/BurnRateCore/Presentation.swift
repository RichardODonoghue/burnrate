import Foundation

/// Desktop-notification permission state, independent of any platform API.
public enum NotificationAuthorization: Sendable, Equatable {
    case authorized
    case denied
    case notDetermined
    case unknown
}

/// Posts desktop notifications. macOS → `UNUserNotificationCenter`; Linux →
/// D-Bus `org.freedesktop.Notifications`; Windows → a WinRT toast.
@MainActor
public protocol NotificationPresenting {
    func authorizationStatus() async -> NotificationAuthorization
    /// Prompts when still undetermined; returns whether notifications are on.
    @discardableResult
    func requestAuthorization() async -> Bool
    /// Delivers a banner. Implementations decide how to fall back when the
    /// platform can't show one (e.g. log under `swift run`).
    func present(title: String, body: String)
}

/// System power/lifecycle events. macOS → `NSWorkspace` wake notifications;
/// Linux → logind `PrepareForSleep`; Windows → `WM_POWERBROADCAST`.
@MainActor
public protocol SystemEventObserving {
    /// Invoked on the main actor when the machine wakes from sleep.
    func onWake(_ handler: @escaping @MainActor @Sendable () -> Void)
}

/// Platform-neutral updater state for menus and settings UI.
public struct UpdateState: Sendable, Equatable {
    /// Version string of an available update, nil when up to date.
    public var availableVersion: String?
    public var isBusy: Bool

    public init(availableVersion: String? = nil, isBusy: Bool = false) {
        self.availableVersion = availableVersion
        self.isBusy = isBusy
    }
}

/// Checks for and installs app updates. macOS swaps the `.app` bundle; Linux
/// and Windows would use their own packaging/update mechanism.
@MainActor
public protocol AppUpdating: AnyObject {
    var state: UpdateState { get }
    /// Called whenever `state` changes, so menus can rebuild.
    var onStateChange: (() -> Void)? { get set }
    func check() async
    func installAvailable() async
}
