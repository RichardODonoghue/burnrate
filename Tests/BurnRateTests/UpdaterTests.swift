import Foundation
import Testing
@testable import BurnRate

struct UpdaterTests {
    // MARK: Version comparison

    @Test func normalizesTags() {
        #expect(Updater.normalizedVersion("v0.2.0") == "0.2.0")
        #expect(Updater.normalizedVersion("0.2.0") == "0.2.0")
        #expect(Updater.normalizedVersion("v1.2.3-beta.1") == "1.2.3")
    }

    @Test func newerVersionsDetected() {
        #expect(Updater.isNewer("0.2.1", than: "0.2.0"))
        #expect(Updater.isNewer("v0.3.0", than: "0.2.9"))
        #expect(Updater.isNewer("1.0.0", than: "0.9.9"))
        #expect(Updater.isNewer("0.10", than: "0.9"))   // numeric, not lexical
        #expect(Updater.isNewer("0.2.1", than: "0.2"))
    }

    @Test func sameOrOlderVersionsRejected() {
        #expect(!Updater.isNewer("0.2.0", than: "0.2.0"))
        #expect(!Updater.isNewer("0.2", than: "0.2.0"))  // missing part == 0
        #expect(!Updater.isNewer("0.1.9", than: "0.2.0"))
        #expect(!Updater.isNewer("v0.2.0", than: "0.2.0"))
    }

    // MARK: Checksum parsing

    @Test func parsesSha256Sums() {
        let text = """
        aaaa  BurnRate-0.2.0-arm64.zip
        bbbb *BurnRate-0.2.0-arm64.dmg
        """
        let parsed = Updater.parseChecksums(text)
        #expect(parsed["BurnRate-0.2.0-arm64.zip"] == "aaaa")
        #expect(parsed["BurnRate-0.2.0-arm64.dmg"] == "bbbb")
    }

    @Test func ignoresMalformedChecksumLines() {
        #expect(Updater.parseChecksums("\nnot-a-hash\n").isEmpty)
    }

    // MARK: Asset selection

    @Test func prefersArm64Zip() {
        let assets = [
            ("BurnRate-0.2.1-arm64.dmg", URL(string: "https://example.com/a.dmg")!),
            ("BurnRate-0.2.1-arm64.zip", URL(string: "https://example.com/a.zip")!),
            ("BurnRate-0.2.1-x86_64.zip", URL(string: "https://example.com/b.zip")!),
        ]
        #expect(Updater.selectZipAsset(assets)?.0 == "BurnRate-0.2.1-arm64.zip")
    }

    @Test func fallsBackToAnyZip() {
        let assets = [("BurnRate.zip", URL(string: "https://example.com/a.zip")!)]
        #expect(Updater.selectZipAsset(assets)?.0 == "BurnRate.zip")
        #expect(Updater.selectZipAsset([]) == nil)
        #expect(Updater.selectZipAsset([("SHA256SUMS", URL(string: "https://example.com/s")!)]) == nil)
    }
}
