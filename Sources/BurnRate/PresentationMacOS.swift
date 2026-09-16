import AppKit
import BurnRateCore
import Foundation
@preconcurrency import UserNotifications

/// macOS notifications via `UNUserNotificationCenter`. Backs both the alert
/// notifier and the Settings permission card.
///
/// Also the center's delegate: without one, banners are delivered quietly
/// while the app is frontmost.
@MainActor
final class UserNotificationPresenter: NSObject, NotificationPresenting, UNUserNotificationCenterDelegate {
    /// `UNUserNotificationCenter` needs a real app bundle; `swift run` and the
    /// test runner have none, so notifications are logged instead.
    private var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

    override init() {
        super.init()
        // Retained by the app (UNUserNotificationCenter holds its delegate weakly).
        if hasBundle {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    func authorizationStatus() async -> NotificationAuthorization {
        guard hasBundle else { return .unknown }
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .unknown
        }
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard hasBundle else { return false }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else {
            return await authorizationStatus() == .authorized
        }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            NSLog("%@", "[milestone] notification authorization granted=\(granted)")
            return granted
        } catch {
            NSLog("%@", "[milestone] notification authorization failed: \(error)")
            return false
        }
    }

    func present(title: String, body: String) {
        guard hasBundle else {
            // Body contains "%" — never pass it as an NSLog format string.
            NSLog("%@", "[milestone] \(title): \(body)")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

/// macOS sleep/wake events via `NSWorkspace`.
@MainActor
final class WorkspaceSystemEvents: SystemEventObserving {
    private var observer: NSObjectProtocol?

    func onWake(_ handler: @escaping @MainActor @Sendable () -> Void) {
        if let observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in handler() }
        }
    }
}
