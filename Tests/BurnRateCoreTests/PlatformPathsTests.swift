import BurnRateCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// `.serialized` because these tests mutate the process-wide `XDG_*`
/// environment; run in parallel they clobber each other (the fallback test
/// unsets the var the XDG test sets).
@Suite(.serialized)
struct PlatformPathsTests {
    @Test func dataDirectoryFallsBackToLocalShare() {
        #if !os(Windows)
        unsetenv("XDG_DATA_HOME")
        #endif
        #expect(FileManagerPaths().dataDirectory.path.hasSuffix("/.local/share"))
    }

    #if !os(Windows)
    // Windows has no setenv/unsetenv; the XDG behaviour is Unix-only anyway.
    @Test func dataDirectoryHonoursXDG() {
        setenv("XDG_DATA_HOME", "/tmp/xdg-data-test", 1)
        defer { unsetenv("XDG_DATA_HOME") }
        #expect(FileManagerPaths().dataDirectory.path == "/tmp/xdg-data-test")
    }

    @Test func configDirectoryHonoursXDG() {
        setenv("XDG_CONFIG_HOME", "/tmp/xdg-config-test", 1)
        defer { unsetenv("XDG_CONFIG_HOME") }
        #expect(FileManagerPaths().configDirectory.path == "/tmp/xdg-config-test")
    }

    /// The OpenCode key lookup follows `$XDG_DATA_HOME` (Fedora users often set
    /// it), so a key that lives there is still found.
    @Test func openCodeCandidatesFollowXDGDataHome() {
        setenv("XDG_DATA_HOME", "/tmp/xdg-data-test", 1)
        defer { unsetenv("XDG_DATA_HOME") }
        let provider = OpenCodeGoUsageAPIProvider()
        #expect(provider.authURLs.first?.path == "/tmp/xdg-data-test/opencode/auth.json")
        #expect(provider.authURLs.contains { $0.path.hasSuffix("/.local/share/opencode/auth.json") })
        #expect(provider.authURLs.contains { $0.path.hasSuffix("/.config/opencode/auth.json") })
    }
    #endif

    // MARK: - sqlite3 discovery

    /// `sqlite3` is not always at `/usr/bin/sqlite3` (Homebrew, Nix, `/usr/local`),
    /// and OpenCode v2 keeps its Go key only in `opencode.db` — so failing to find
    /// the binary silently hid the whole subscription.
    @Test func sqlite3IsFoundOnPath() {
        let found = ProcessSQLiteRunner.sqlite3Executable(
            environment: ["PATH": "/opt/tools/bin:/usr/bin"],
            isExecutable: { $0 == "/opt/tools/bin/sqlite3" }
        )
        #expect(found == "/opt/tools/bin/sqlite3")
    }

    @Test func sqlite3FallsBackToWellKnownLocations() {
        // Nothing on PATH — the hardcoded fallbacks must still be tried.
        let found = ProcessSQLiteRunner.sqlite3Executable(
            environment: ["PATH": "/nonexistent"],
            isExecutable: { $0 == "/usr/local/bin/sqlite3" }
        )
        #expect(found == "/usr/local/bin/sqlite3")
    }

    @Test func sqlite3ReportsMissingRunner() {
        #expect(ProcessSQLiteRunner.sqlite3Executable(
            environment: ["PATH": "/nonexistent"],
            isExecutable: { _ in false }
        ) == nil)
    }

    /// An unset or empty `$PATH` must not defeat the absolute fallbacks.
    @Test func sqlite3SurvivesUnsetPath() {
        #expect(ProcessSQLiteRunner.sqlite3Executable(
            environment: [:],
            isExecutable: { $0 == "/usr/bin/sqlite3" }
        ) == "/usr/bin/sqlite3")
        #expect(ProcessSQLiteRunner.sqlite3Executable(
            environment: ["PATH": ""],
            isExecutable: { $0 == "/usr/bin/sqlite3" }
        ) == "/usr/bin/sqlite3")
    }

    /// Real lookup on the host: if `sqlite3` is installed we must actually find
    /// it, and the path we return has to be runnable.
    @Test func sqlite3IsResolvableOnThisMachine() throws {
        guard let exe = ProcessSQLiteRunner.sqlite3Executable() else {
            // No CLI on this host: `query` must say so rather than crash.
            #expect(throws: SQLiteError.runnerUnavailable) {
                try ProcessSQLiteRunner().query(
                    databaseAt: URL(fileURLWithPath: "/nonexistent.db"),
                    sql: "SELECT 1;"
                )
            }
            return
        }
        #expect(FileManager.default.isExecutableFile(atPath: exe))
    }

    // MARK: - generic tool discovery

    /// `notify-send` and `xdg-open` were hardcoded to `/usr/bin/…`, which
    /// silently disabled alerts and the updater link on any other layout.
    @Test func locatesAnyToolOnPath() {
        #expect(ExternalTool.locate(
            named: "notify-send",
            environment: ["PATH": "/opt/bin:/usr/bin"],
            isExecutable: { $0 == "/opt/bin/notify-send" }
        ) == "/opt/bin/notify-send")
    }

    @Test func locatesToolInHomebrewKeg() {
        // The keg directory is named after the package (`sqlite`), which the
        // generic `/usr/local/opt/<name>` pattern cannot derive from `sqlite3`.
        #expect(ProcessSQLiteRunner.sqlite3Executable(
            environment: ["PATH": ""],
            isExecutable: { $0 == "/usr/local/opt/sqlite/bin/sqlite3" }
        ) == "/usr/local/opt/sqlite/bin/sqlite3")
    }

    @Test func reportsMissingTool() {
        #expect(ExternalTool.locate(
            named: "definitely-not-a-real-tool",
            environment: ["PATH": "/usr/bin:/bin"],
            isExecutable: { _ in false }
        ) == nil)
    }

    /// A tool present on PATH wins over the absolute fallbacks.
    @Test func pathBeatsAbsoluteFallbacks() {
        #expect(ExternalTool.locate(
            named: "gio",
            environment: ["PATH": "/custom/bin"],
            isExecutable: { $0 == "/custom/bin/gio" || $0 == "/usr/bin/gio" }
        ) == "/custom/bin/gio")
    }
}
