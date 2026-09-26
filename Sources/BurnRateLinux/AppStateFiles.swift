import BurnRateCore
import Foundation

/// The app's small JSON state files in the app data directory: settings, alert
/// bookkeeping and chart history. Linux has no UserDefaults, so these are the
/// equivalent — and they must survive a restart, or every launch looks like a
/// first run (milestones re-fire, the once-per-day cost gate resets, charts
/// start empty).
///
/// Writes are atomic: a crash mid-write would otherwise leave truncated JSON
/// that fails to decode, silently discarding the state.
enum AppStateFiles {
    static func url(_ name: String, paths: any AppPaths = FileManagerPaths()) -> URL {
        paths.appDirectory.appendingPathComponent(name)
    }

    static func load<Value: Decodable>(
        _ type: Value.Type, from name: String, paths: any AppPaths = FileManagerPaths()
    ) -> Value? {
        guard let data = try? Data(contentsOf: url(name, paths: paths)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<Value: Encodable>(
        _ value: Value, to name: String, paths: any AppPaths = FileManagerPaths()
    ) {
        let destination = url(name, paths: paths)
        try? FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: destination, options: .atomic)
    }
}
