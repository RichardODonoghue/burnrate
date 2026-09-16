import AppKit
import BurnRateCore
import CryptoKit
import Foundation
import UserNotifications

/// A newer release discovered on GitHub.
struct AvailableUpdate: Equatable {
    let version: String
    let tag: String
    let zipName: String
    let zipURL: URL
    let checksumURL: URL?
    let releaseURL: URL
}

enum UpdateError: LocalizedError {
    case noZipAsset
    case checksumMissing
    case checksumMismatch(expected: String, actual: String)
    case unzipFailed
    case invalidBundle(String)
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .noZipAsset:
            return "This release has no arm64 zip artifact."
        case .checksumMissing:
            return "This release isn't verifiable (no SHA256SUMS asset). Install it manually from the release page."
        case .checksumMismatch(let expected, let actual):
            return "Checksum mismatch — download ignored (expected \(expected.prefix(12))…, got \(actual.prefix(12))…)."
        case .unzipFailed:
            return "The downloaded archive could not be unpacked."
        case .invalidBundle(let reason):
            return "The downloaded app failed validation: \(reason)"
        case .notWritable(let path):
            return "Can't write to \(path) — move BurnRate to a writable location or update manually."
        }
    }
}

/// Checks GitHub Releases for a newer version, verifies the download against
/// the release's published SHA-256, then swaps the running bundle in place.
///
/// Deliberately not Sparkle: we ship ad-hoc signed builds (no stable signing
/// identity), which Sparkle can't use to validate an update. Temporary until
/// the app is distributed through the App Store.
@MainActor
final class Updater: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(String)
        case installing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var available: AvailableUpdate?

    /// Called whenever `status`/`available` change, so the menu can rebuild.
    var onStateChange: (() -> Void)?

    nonisolated static let owner = "RichardODonoghue"
    nonisolated static let repo = "burnrate"
    nonisolated static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest"
    )!
    nonisolated static let checkInterval: TimeInterval = 24 * 3600
    private static let notifiedKey = "updaterNotifiedVersions"

    private let currentVersion: String
    private let session: URLSession
    private let defaults: UserDefaults
    private var timer: Timer?

    init(currentVersion: String = AppInfo.version,
         session: URLSession = .shared,
         defaults: UserDefaults = .standard) {
        self.currentVersion = currentVersion
        self.session = session
        self.defaults = defaults
    }

    /// Check now, then every 24h while running.
    func start() {
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.check() }
        }
    }

    func check() async {
        guard !status.isBusy else { return }
        setStatus(.checking)
        do {
            let release = try await fetchLatestRelease()
            guard let release else {
                available = nil
                setStatus(.upToDate)
                return
            }
            guard Self.isNewer(release.version, than: currentVersion) else {
                available = nil
                setStatus(.upToDate)
                return
            }
            available = release
            setStatus(.available(release.version))
            notifyIfNeeded(release.version)
        } catch {
            setStatus(.failed(error.localizedDescription))
        }
    }

    // MARK: - Install

    func install(_ update: AvailableUpdate) async {
        guard !status.isBusy else { return }
        setStatus(.downloading(update.version))
        do {
            let zip = try await download(update)
            setStatus(.installing)
            let extracted = try unpack(zip)
            try validate(bundleAt: extracted, version: update.version)
            try replaceRunningBundle(with: extracted)
            relaunchAfterExit()
        } catch {
            setStatus(.failed(error.localizedDescription))
        }
    }

    /// Downloads the release zip and verifies it against the SHA256SUMS asset.
    private func download(_ update: AvailableUpdate) async throws -> URL {
        let (tempURL, response) = try await session.download(from: update.zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let zip = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(update.zipName)
        try FileManager.default.createDirectory(
            at: zip.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: zip)

        guard let checksumURL = update.checksumURL else { throw UpdateError.checksumMissing }
        let (data, _) = try await session.data(from: checksumURL)
        let checksums = Self.parseChecksums(String(decoding: data, as: UTF8.self))
        guard let expected = checksums[update.zipName] else { throw UpdateError.checksumMissing }

        let digest = SHA256.hash(data: try Data(contentsOf: zip))
            .map { String(format: "%02x", $0) }.joined()
        guard digest.caseInsensitiveCompare(expected) == .orderedSame else {
            throw UpdateError.checksumMismatch(expected: expected, actual: digest)
        }
        return zip
    }

    private func unpack(_ zip: URL) throws -> URL {
        let dest = zip.deletingLastPathComponent().appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        guard Self.runProcess("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path]) == 0 else {
            throw UpdateError.unzipFailed
        }
        let bundle = dest.appendingPathComponent("BurnRate.app")
        guard FileManager.default.fileExists(atPath: bundle.path) else {
            throw UpdateError.invalidBundle("BurnRate.app is missing from the archive")
        }
        return bundle
    }

    /// The archive must be a BurnRate build of the expected version, and its
    /// signature must verify before we put it in place.
    private func validate(bundleAt url: URL, version: String) throws {
        guard let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let bundleVersion = plist["CFBundleShortVersionString"] as? String
        else {
            throw UpdateError.invalidBundle("unreadable Info.plist")
        }
        guard bundleID == Bundle.main.bundleIdentifier else {
            throw UpdateError.invalidBundle("bundle identifier \(bundleID) doesn't match")
        }
        guard bundleVersion == version else {
            throw UpdateError.invalidBundle("version \(bundleVersion) doesn't match \(version)")
        }
        guard Self.runProcess("/usr/bin/codesign", ["--verify", "--deep", url.path]) == 0 else {
            throw UpdateError.invalidBundle("code signature failed verification")
        }
    }

    /// Swaps the running bundle for the new one. macOS keeps the running
    /// process mapped, so replacing the directory on disk is safe.
    private func replaceRunningBundle(with newBundle: URL) throws {
        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }
        let backup = parent.appendingPathComponent("BurnRate.app.replaced-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: current, to: backup)
        do {
            try FileManager.default.moveItem(at: newBundle, to: current)
        } catch {
            try? FileManager.default.moveItem(at: backup, to: current) // roll back
            throw error
        }
        // Not quarantined when we download it, but strip defensively: an
        // ad-hoc signed bundle would otherwise be blocked on first launch.
        _ = Self.runProcess("/usr/bin/xattr", ["-dr", "com.apple.quarantine", current.path])
        try? FileManager.default.removeItem(at: backup)
    }

    /// Relaunch once this process is gone — the single-instance guard would
    /// otherwise kill the freshly launched copy.
    private func relaunchAfterExit() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let path = Bundle.main.bundleURL.path
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: - GitHub

    private func fetchLatestRelease() async throws -> AvailableUpdate? {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        // 404 = no releases yet (or repo renamed); nothing to offer.
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw URLError(.badServerResponse) }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let releaseURLString = obj["html_url"] as? String,
              let releaseURL = URL(string: releaseURLString)
        else { throw URLError(.cannotParseResponse) }

        let assets = (obj["assets"] as? [[String: Any]] ?? []).compactMap { asset -> (String, URL)? in
            guard let name = asset["name"] as? String,
                  let urlString = asset["browser_download_url"] as? String,
                  let url = URL(string: urlString)
            else { return nil }
            return (name, url)
        }
        guard let zip = Self.selectZipAsset(assets) else { throw UpdateError.noZipAsset }
        let checksumURL = assets.first { $0.0 == "SHA256SUMS" }?.1

        return AvailableUpdate(
            version: Self.normalizedVersion(tag),
            tag: tag,
            zipName: zip.0,
            zipURL: zip.1,
            checksumURL: checksumURL,
            releaseURL: releaseURL
        )
    }

    // MARK: - Notification

    private func notifyIfNeeded(_ version: String) {
        var notified = Set(defaults.stringArray(forKey: Self.notifiedKey) ?? [])
        guard !notified.contains(version), Bundle.main.bundleIdentifier != nil else { return }
        notified.insert(version)
        defaults.set(Array(notified), forKey: Self.notifiedKey)

        let content = UNMutableNotificationContent()
        content.title = "BurnRate update available"
        content.body = "Version \(version) is ready. Open the BurnRate menu to install it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "burnrate-update-\(version)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - State

    private func setStatus(_ status: Status) {
        self.status = status
        onStateChange?()
    }

    // MARK: - Pure helpers (tested)

    /// "v0.2.0" / "0.2" → "0.2.0"-ish dotted version, dropping any suffix.
    nonisolated static func normalizedVersion(_ tag: String) -> String {
        let trimmed = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return trimmed.split(separator: "-").first.map(String.init) ?? trimmed
    }

    /// Semver-ish comparison of dotted numeric versions; missing components
    /// count as 0, so "0.2" == "0.2.0" and "0.10" > "0.9".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let lhs = components(of: candidate)
        let rhs = components(of: current)
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private nonisolated static func components(of version: String) -> [Int] {
        normalizedVersion(version).split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Parses `shasum -a 256` output: "<hash>  <filename>" per line.
    nonisolated static func parseChecksums(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let hash = String(parts[0])
            // Filenames may be prefixed with "*" in some shasum outputs.
            let name = String(parts[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*"))
            result[name] = hash
        }
        return result
    }

    /// The arm64 app zip, preferring an exact version match.
    nonisolated static func selectZipAsset(_ assets: [(String, URL)]) -> (String, URL)? {
        let zips = assets.filter { $0.0.lowercased().hasSuffix(".zip") }
        return zips.first { $0.0.lowercased().contains("arm64") } ?? zips.first
    }

    private nonisolated static func runProcess(_ path: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

extension Updater: AppUpdating {
    var state: UpdateState {
        UpdateState(availableVersion: available?.version, isBusy: status.isBusy)
    }

    func installAvailable() async {
        guard let update = available else { return }
        await install(update)
    }
}
