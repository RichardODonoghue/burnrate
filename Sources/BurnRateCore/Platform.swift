import Foundation

/// Filesystem locations the app uses. Abstracted so a Linux/Windows build can
/// resolve XDG / %APPDATA% instead of the macOS layout.
public protocol AppPaths: Sendable {
    var homeDirectory: URL { get }
    var applicationSupportDirectory: URL { get }
}

extension AppPaths {
    /// Per-app data directory (created lazily by callers).
    public var appDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("BurnRate")
    }
}

/// Default `AppPaths` backed by `FileManager`. On macOS this is
/// `~/Library/Application Support`; other platforms substitute their own.
public struct FileManagerPaths: AppPaths {
    public init() {}

    public var homeDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
    }

    public var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? homeDirectory.appendingPathComponent(".local/share")
    }
}

/// Reads a generic password / secret. macOS uses the Keychain; Linux would use
/// libsecret, Windows the Credential Manager.
public protocol CredentialReading: Sendable {
    /// Raw secret bytes for `service`, or nil when absent.
    func genericPassword(service: String) -> Data?
}

/// Runs a read-only SQL query. macOS shells out to `sqlite3`; other platforms
/// link libsqlite3 (or a bundled build).
public protocol SQLiteQuerying: Sendable {
    /// Returns the query output (tab-separated rows, newline-delimited).
    func query(databaseAt path: URL, sql: String) throws -> String
}

public enum SQLiteError: Error {
    case runnerUnavailable
    case queryFailed(Int32)
}
