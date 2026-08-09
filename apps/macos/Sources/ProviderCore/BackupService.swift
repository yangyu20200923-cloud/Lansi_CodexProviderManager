import Foundation
import SQLite3
import CryptoKit

public enum BackupError: Error {
    case sqlite(String)
    case checksumMismatch(String)
}

public struct BackupManifest: Codable, Equatable, Sendable {
    public let directory: URL
    public var backupID: String { directory.lastPathComponent }
    public let createdAt: Date
    public let files: [String]
    public let checksums: [String: String]
    public var isPinned: Bool

    public init(directory: URL, createdAt: Date, files: [String], checksums: [String: String] = [:], isPinned: Bool) {
        self.directory = directory
        self.createdAt = createdAt
        self.files = files
        self.checksums = checksums
        self.isPinned = isPinned
    }
}

public final class BackupService: @unchecked Sendable {
    private let backupRoot: URL?
    private let retentionCount: Int

    public init(backupRoot: URL? = nil, retentionCount: Int = 10) {
        self.backupRoot = backupRoot
        self.retentionCount = retentionCount
    }

    public func create(codexHome: URL) throws -> BackupManifest {
        let root = backupRoot ?? codexHome.appendingPathComponent("backups/CodexProviderManager")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent(stamp)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var files: [String] = []
        for name in ["config.toml", "state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
            let source = codexHome.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent(name)
            if name == "state_5.sqlite" { try copySQLiteDatabase(from: source, to: destination) }
            else { try FileManager.default.copyItem(at: source, to: destination) }
            files.append(name)
        }
        var checksums: [String: String] = [:]
        for name in files {
            checksums[name] = Self.sha256(try Data(contentsOf: directory.appendingPathComponent(name)))
        }
        let manifest = BackupManifest(directory: directory, createdAt: Date(), files: files, checksums: checksums, isPinned: false)
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try prune(root: root)
        return manifest
    }

    public func restore(_ manifest: BackupManifest, to codexHome: URL) throws {
        for name in manifest.files {
            guard let expected = manifest.checksums[name] else { continue }
            let source = manifest.directory.appendingPathComponent(name)
            guard Self.sha256(try Data(contentsOf: source)) == expected else {
                throw BackupError.checksumMismatch(name)
            }
        }
        for sidecar in ["state_5.sqlite-wal", "state_5.sqlite-shm"] {
            let current = codexHome.appendingPathComponent(sidecar)
            if FileManager.default.fileExists(atPath: current.path) {
                let quarantine = manifest.directory.appendingPathComponent("failed-\(UUID().uuidString)-\(sidecar)")
                try FileManager.default.moveItem(at: current, to: quarantine)
            }
        }
        for name in manifest.files where name == "config.toml" || name == "state_5.sqlite" {
            let source = manifest.directory.appendingPathComponent(name)
            let target = codexHome.appendingPathComponent(name)
            try AtomicFile.replace(target, with: Data(contentsOf: source))
        }
        for name in manifest.files where name == "config.toml" || name == "state_5.sqlite" {
            guard let expected = manifest.checksums[name] else { continue }
            let target = codexHome.appendingPathComponent(name)
            guard Self.sha256(try Data(contentsOf: target)) == expected else {
                throw BackupError.checksumMismatch(name)
            }
        }
    }

    private func prune(root: URL) throws {
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in directories.dropFirst(retentionCount) {
            let manifestURL = url.appendingPathComponent("manifest.json")
            let manifest = try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
            if manifest?.isPinned != true { try FileManager.default.removeItem(at: url) }
        }
    }

    private func copySQLiteDatabase(from source: URL, to destination: URL) throws {
        var sourceDB: OpaquePointer?
        var destinationDB: OpaquePointer?
        guard sqlite3_open_v2(source.path, &sourceDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let sourceDB else {
            throw BackupError.sqlite("Cannot open source state database.")
        }
        defer { sqlite3_close(sourceDB) }
        guard sqlite3_open_v2(destination.path, &destinationDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let destinationDB else {
            throw BackupError.sqlite("Cannot create state database backup.")
        }
        defer { sqlite3_close(destinationDB) }
        guard let backup = sqlite3_backup_init(destinationDB, "main", sourceDB, "main") else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(destinationDB)))
        }
        let step = sqlite3_backup_step(backup, -1)
        let finish = sqlite3_backup_finish(backup)
        guard step == SQLITE_DONE, finish == SQLITE_OK else {
            throw BackupError.sqlite(String(cString: sqlite3_errmsg(destinationDB)))
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
