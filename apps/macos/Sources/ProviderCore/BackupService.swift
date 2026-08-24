import Foundation
import SQLite3
import CryptoKit
import Darwin

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
    /// Logical size of the whole backup directory in bytes (managed files
    /// plus the preserved clone snapshot). Zero for manifests written before
    /// this field existed.
    public let logicalBytes: Int64
    public var isPinned: Bool

    public init(
        directory: URL,
        createdAt: Date,
        files: [String],
        checksums: [String: String] = [:],
        logicalBytes: Int64 = 0,
        isPinned: Bool
    ) {
        self.directory = directory
        self.createdAt = createdAt
        self.files = files
        self.checksums = checksums
        self.logicalBytes = logicalBytes
        self.isPinned = isPinned
    }

    enum CodingKeys: String, CodingKey {
        case directory, createdAt, files, checksums, logicalBytes, isPinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        directory = try container.decode(URL.self, forKey: .directory)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        files = try container.decode([String].self, forKey: .files)
        checksums = try container.decodeIfPresent([String: String].self, forKey: .checksums) ?? [:]
        logicalBytes = try container.decodeIfPresent(Int64.self, forKey: .logicalBytes) ?? 0
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(directory, forKey: .directory)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(files, forKey: .files)
        try container.encode(checksums, forKey: .checksums)
        try container.encode(logicalBytes, forKey: .logicalBytes)
        try container.encode(isPinned, forKey: .isPinned)
    }
}

public struct BackupSummary: Codable, Equatable, Sendable {
    public let backupID: String
    public let createdAt: Date
    public let logicalBytes: Int64
    public let isPinned: Bool

    public init(backupID: String, createdAt: Date, logicalBytes: Int64, isPinned: Bool) {
        self.backupID = backupID
        self.createdAt = createdAt
        self.logicalBytes = logicalBytes
        self.isPinned = isPinned
    }
}

public final class BackupService: @unchecked Sendable {
    private let backupRoot: URL?
    private let retentionCount: Int
    private let maxBackupBytes: Int64
    private let maxBackupAgeDays: Int
    private static let preservedRootNames = ["sessions", "skills", "plugins", "mcp"]

    public init(
        backupRoot: URL? = nil,
        retentionCount: Int = 5,
        maxBackupBytes: Int64 = 20 * 1024 * 1024 * 1024,
        maxBackupAgeDays: Int = 14
    ) {
        self.backupRoot = backupRoot
        self.retentionCount = retentionCount
        self.maxBackupBytes = maxBackupBytes
        self.maxBackupAgeDays = maxBackupAgeDays
    }

    public func create(codexHome: URL) throws -> BackupManifest {
        let root = root(for: codexHome)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let directory = root.appendingPathComponent(stamp)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        for name in ["config.toml", "state_5.sqlite", "state_5.sqlite-wal", "state_5.sqlite-shm"] {
            let source = codexHome.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            let destination = directory.appendingPathComponent(name)
            if name == "state_5.sqlite" { try copySQLiteDatabase(from: source, to: destination) }
            else { try FileManager.default.copyItem(at: source, to: destination) }
        }
        var preservedRoots: [String: Bool] = [:]
        let preservedDirectory = directory.appendingPathComponent("preserved")
        for name in Self.preservedRootNames {
            let source = codexHome.appendingPathComponent(name)
            let exists = FileManager.default.fileExists(atPath: source.path)
            preservedRoots[name] = exists
            guard exists else { continue }
            try FileManager.default.createDirectory(at: preservedDirectory, withIntermediateDirectories: true)
            // Preserved roots such as `sessions` can be multiple gigabytes.
            // An APFS clone is a copy-on-write snapshot: it completes in
            // seconds, keeps the backup stable even when Codex keeps writing
            // session files, and only falls back to a physical copy on
            // non-APFS volumes.
            try Self.copyPreservedPath(from: source, to: preservedDirectory.appendingPathComponent(name))
        }
        let preservedMarker = directory.appendingPathComponent("preserved-roots.json")
        try JSONEncoder().encode(preservedRoots).write(to: preservedMarker, options: .atomic)
        let files = try backupFilePaths(in: directory)
        var checksums: [String: String] = [:]
        for name in files {
            // Managed files are hashed; preserved snapshots are protected by
            // the clone plus count/size verification so a switch does not
            // spend minutes hashing gigabytes of session rollouts.
            if name.hasPrefix("preserved/") { continue }
            checksums[name] = Self.sha256(try Data(contentsOf: directory.appendingPathComponent(name)))
        }
        let manifest = BackupManifest(
            directory: directory,
            createdAt: Date(),
            files: files,
            checksums: checksums,
            logicalBytes: Self.logicalSize(of: directory),
            isPinned: false
        )
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        try prune(root: root)
        return manifest
    }

    /// Governed retention: a backup is removed when it is the oldest
    /// non-pinned entry and (a) it is older than `maxBackupAgeDays`, or
    /// (b) more than `retentionCount` backups remain, or (c) the surviving
    /// backups would still exceed `maxBackupBytes`. Pinned backups are never
    /// removed automatically.
    private func prune(root: URL) throws {
        var entries: [(url: URL, manifest: BackupManifest)] = []
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json"))) else { continue }
            entries.append((url, manifest))
        }
        entries.sort { $0.manifest.createdAt < $1.manifest.createdAt }

        var survivors = entries
        var toRemove: [URL] = []
        let cutoff = Date().addingTimeInterval(-Double(maxBackupAgeDays) * 86_400)

        // Age limit first: expired non-pinned backups go before any count or
        // byte pressure is considered.
        survivors.removeAll { entry in
            guard entry.manifest.createdAt < cutoff, !entry.manifest.isPinned else { return false }
            toRemove.append(entry.url)
            return true
        }

        // Then count and byte limits, always evicting the oldest non-pinned
        // backup until both constraints hold.
        while true {
            let nonPinned = survivors.filter { !$0.manifest.isPinned }
            let totalBytes = survivors.reduce(Int64(0)) { $0 + Self.byteCount(manifest: $1.manifest, url: $1.url) }
            if nonPinned.count <= retentionCount, totalBytes <= maxBackupBytes { break }
            guard let oldest = nonPinned.first else { break }
            toRemove.append(oldest.url)
            survivors.removeAll { $0.url == oldest.url }
        }

        for url in toRemove {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func byteCount(manifest: BackupManifest, url: URL) -> Int64 {
        manifest.logicalBytes > 0 ? manifest.logicalBytes : logicalSize(of: url)
    }

    /// Logical size of a directory tree in bytes (regular files only).
    public static func logicalSize(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    public func backupSummaries(codexHome: URL) throws -> [BackupSummary] {
        let root = root(for: codexHome)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let summaries = directories.compactMap { url -> BackupSummary? in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: url.appendingPathComponent("manifest.json"))) else { return nil }
            return BackupSummary(
                backupID: manifest.backupID,
                createdAt: manifest.createdAt,
                logicalBytes: manifest.logicalBytes,
                isPinned: manifest.isPinned
            )
        }
        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(backupID: String, codexHome: URL) throws {
        let root = root(for: codexHome).standardizedFileURL
        let url = root.appendingPathComponent(backupID).standardizedFileURL
        guard url.deletingLastPathComponent() == root else {
            throw BackupError.checksumMismatch("backup id escapes the backup root")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BackupError.checksumMismatch("backup does not exist: \(backupID)")
        }
        try FileManager.default.removeItem(at: url)
    }

    public func setPinned(backupID: String, isPinned: Bool, codexHome: URL) throws {
        let root = root(for: codexHome)
        let url = root.appendingPathComponent(backupID)
        let manifestURL = url.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL))
        manifest.isPinned = isPinned
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
    }

    public func pruneNow(codexHome: URL) throws {
        let root = root(for: codexHome)
        guard FileManager.default.fileExists(atPath: root.path) else { return }
        try prune(root: root)
    }

    /// Returns only a checksum-protected manifest that physically belongs to this Codex home's backup root.
    public func latestBackup(codexHome: URL) throws -> BackupManifest? {
        let root = root(for: codexHome)
        guard FileManager.default.fileExists(atPath: root.path) else { return nil }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).compactMap { directory -> BackupManifest? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL)),
                  manifest.directory.standardizedFileURL.path == directory.standardizedFileURL.path else { return nil }
            return manifest
        }
        return candidates.max { $0.createdAt < $1.createdAt }
    }

    /// Provides a migration fallback for installations that predate the persistent baseline store.
    /// Only checksum-valid backups whose active Provider was OpenAI are considered.
    public func latestOpenAIConfigurationBaseline(codexHome: URL) -> OpenAIConfigurationBaseline? {
        let root = root(for: codexHome)
        guard let directories = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        let manifests = directories.compactMap { directory -> BackupManifest? in
            guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard let manifest = try? JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: manifestURL)),
                  manifest.directory.standardizedFileURL.path == directory.standardizedFileURL.path else { return nil }
            return manifest
        }.sorted { $0.createdAt > $1.createdAt }

        for manifest in manifests {
            guard let expected = manifest.checksums["config.toml"],
                  manifest.files.contains("config.toml") else { continue }
            let configURL = manifest.directory.appendingPathComponent("config.toml")
            guard let data = try? Data(contentsOf: configURL),
                  Self.sha256(data) == expected,
                  let config = try? CodexConfigService().read(from: configURL),
                  config.activeProvider == ProviderID.openAI.rawValue else { continue }
            return CodexConfigService().openAIConfigurationBaseline(from: config)
        }
        return nil
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
        try restorePreservedRoots(from: manifest, to: codexHome)
    }

    private func root(for codexHome: URL) -> URL {
        backupRoot ?? codexHome.appendingPathComponent("backups/CodexProviderManager")
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

    private func backupFilePaths(in directory: URL) throws -> [String] {
        let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey])?
            .compactMap { $0 as? URL }
            .filter { url in
                isChecksumFile(url, in: directory)
            } ?? []
        let rootPath = directory.standardizedFileURL.path + "/"
        return files
            .map { $0.standardizedFileURL.path.replacingOccurrences(of: rootPath, with: "") }
            .sorted()
    }

    /// Directory symlinks such as plugin-cache `latest` must be preserved but cannot be checksummed as files.
    private func isChecksumFile(_ url: URL, in root: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.standardizedFileURL.path + "/"
        guard resolved.path.hasPrefix(rootPath),
              let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return true
    }

    private func restorePreservedRoots(from manifest: BackupManifest, to codexHome: URL) throws {
        let markerName = "preserved-roots.json"
        guard manifest.files.contains(markerName) else { return }
        let marker = manifest.directory.appendingPathComponent(markerName)
        let roots = try JSONDecoder().decode([String: Bool].self, from: Data(contentsOf: marker))
        for name in Self.preservedRootNames {
            guard let existedBefore = roots[name] else { throw BackupError.checksumMismatch(markerName) }
            let source = manifest.directory.appendingPathComponent("preserved/\(name)")
            let target = codexHome.appendingPathComponent(name)
            if existedBefore {
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw BackupError.checksumMismatch("preserved/\(name)")
                }
                try replacePreservedPath(source: source, target: target, backupDirectory: manifest.directory)
                try verifyRestoredRoot(name, manifest: manifest, codexHome: codexHome)
            } else if FileManager.default.fileExists(atPath: target.path) {
                let quarantine = manifest.directory.appendingPathComponent("failed-\(UUID().uuidString)-\(name)")
                try FileManager.default.moveItem(at: target, to: quarantine)
            }
        }
    }

    private func replacePreservedPath(source: URL, target: URL, backupDirectory: URL) throws {
        let stage = target.deletingLastPathComponent()
            .appendingPathComponent(".restore-provider-\(UUID().uuidString)-\(target.lastPathComponent)")
        defer { try? FileManager.default.removeItem(at: stage) }
        try Self.copyPreservedPath(from: source, to: stage)
        if FileManager.default.fileExists(atPath: target.path) {
            let quarantine = backupDirectory.appendingPathComponent("failed-\(UUID().uuidString)-\(target.lastPathComponent)")
            try FileManager.default.moveItem(at: target, to: quarantine)
        }
        try FileManager.default.moveItem(at: stage, to: target)
    }

    private func verifyRestoredRoot(_ name: String, manifest: BackupManifest, codexHome: URL) throws {
        // Preserved snapshots are restored through APFS clones; hashing every
        // session rollout again would make recovery as slow as the original
        // backup. Comparing file count and total bytes keeps the check fast
        // while still catching truncated or partial restores.
        let source = manifest.directory.appendingPathComponent("preserved/\(name)")
        let target = codexHome.appendingPathComponent(name)
        let sourceStats = try Self.directoryStats(source)
        let targetStats = try Self.directoryStats(target)
        guard sourceStats.fileCount == targetStats.fileCount,
              sourceStats.totalBytes == targetStats.totalBytes else {
            throw BackupError.checksumMismatch("preserved/\(name)")
        }
    }

    private static func copyPreservedPath(from source: URL, to destination: URL) throws {
        if clonefile(source.path, destination.path, 0) == 0 { return }
        // Fall back to a physical copy on non-APFS volumes (for example a
        // network or exFAT home directory).
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func directoryStats(_ url: URL) throws -> (fileCount: Int, totalBytes: Int64) {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var fileCount = 0
        var totalBytes: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { continue }
            fileCount += 1
            totalBytes += Int64(values.fileSize ?? 0)
        }
        return (fileCount, totalBytes)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
