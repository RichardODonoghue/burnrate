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

    /// XDG data dir on Linux (`$XDG_DATA_HOME`, else `~/.local/share`).
    public var dataDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".local/share")
    }

    /// XDG config dir on Linux (`$XDG_CONFIG_HOME`, else `~/.config`).
    public var configDirectory: URL {
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: xdg, isDirectory: true)
        }
        return homeDirectory.appendingPathComponent(".config")
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

public enum SQLiteError: Error, Equatable {
    case runnerUnavailable
    case queryFailed(Int32)
}

/// Locates the external command-line tools the app shells out to.
///
/// Distros disagree about where these live (Homebrew, Nix, `/usr/local`, and
/// minimal images omit them entirely), so a hardcoded absolute path silently
/// disables whatever feature needed the tool — invisibly, because the tool is
/// only reached on a code path the user may never exercise. Walk `$PATH`
/// first, then the well-known absolute locations.
public enum ExternalTool {
    /// - Parameter additionalCandidates: extra absolute paths to try after
    ///   `$PATH` and the generic fallbacks — for kegs whose directory is named
    ///   after the *package* rather than the binary (`sqlite`, not `sqlite3`).
    public nonisolated static func locate(
        named name: String,
        additionalCandidates: [String] = [],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let path = environment["PATH"] {
            candidates += path
                .split(separator: ":", omittingEmptySubsequences: true)
                .map { "\($0)/\(name)" }
        }
        candidates += [
            "/usr/bin/\(name)",                 // macOS, Fedora, Debian
            "/bin/\(name)",
            "/usr/local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",        // Homebrew, Apple Silicon
        ]
        candidates += additionalCandidates
        return candidates.first(where: isExecutable)
    }
}

/// `SQLiteQuerying` via the `sqlite3` CLI in read-only mode (macOS/Linux).
/// Windows would link a bundled sqlite3 instead.
public struct ProcessSQLiteRunner: SQLiteQuerying {
    public init() {}

    /// Locates the `sqlite3` CLI. This one matters more than it looks: OpenCode
    /// v2 keeps its `opencode-go` key only in `opencode.db`, so a missing
    /// runner made the whole subscription read as "no OpenCode key".
    public nonisolated static func sqlite3Executable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        ExternalTool.locate(
            named: "sqlite3",
            // Homebrew's keg is named after the package, not the binary.
            additionalCandidates: ["/usr/local/opt/sqlite/bin/sqlite3"],
            environment: environment, isExecutable: isExecutable)
    }

    public func query(databaseAt path: URL, sql: String) throws -> String {
        guard let executable = Self.sqlite3Executable() else {
            throw SQLiteError.runnerUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
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
