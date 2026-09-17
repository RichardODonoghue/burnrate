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

/// `SQLiteQuerying` via the `sqlite3` CLI in read-only mode (macOS/Linux).
/// Windows would link a bundled sqlite3 instead.
public struct ProcessSQLiteRunner: SQLiteQuerying {
    public init() {}

    public func query(databaseAt path: URL, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", path.path, "-separator", "\t", sql]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        // Read the pipe to EOF BEFORE waiting: draining concurrently avoids
        // deadlock when output exceeds the pipe buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw SQLiteError.queryFailed(process.terminationStatus)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Credential reader for platforms without a secret store: always misses
/// (credentials are read from the CLI dotfiles instead).
public struct NoopCredentialReader: CredentialReading {
    public init() {}
    public func genericPassword(service: String) -> Data? { nil }
}
