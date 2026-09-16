import BurnRateCore
import Foundation

/// macOS Keychain-backed `CredentialReading`, via `/usr/bin/security`.
struct KeychainCredentialReader: CredentialReading {
    func genericPassword(service: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil // no Keychain entry / unavailable
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}

/// macOS `SQLiteQuerying` via `/usr/bin/sqlite3` in read-only mode.
struct ProcessSQLiteRunner: SQLiteQuerying {
    func query(databaseAt path: URL, sql: String) throws -> String {
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
