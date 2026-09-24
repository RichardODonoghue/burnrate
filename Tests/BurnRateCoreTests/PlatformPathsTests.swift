import BurnRateCore
import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
}
