import Foundation
import SQLite3
import CryptoKit
import XCTest
@testable import ProviderCore

final class BackupServiceTests: XCTestCase {
    func testCreateBacksUpSyntheticConfigAndSQLiteState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"custom\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let database = home.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE threads (id TEXT); INSERT INTO threads VALUES ('fixture-thread');", nil, nil, nil), SQLITE_OK)

        let manifest = try BackupService(backupRoot: home.appendingPathComponent("backups")).create(codexHome: home)
        let manifestText = try String(contentsOf: manifest.directory.appendingPathComponent("manifest.json"), encoding: .utf8)

        XCTAssertTrue(manifest.files.contains("config.toml"))
        XCTAssertTrue(manifest.files.contains("state_5.sqlite"))
        XCTAssertEqual(manifest.checksums.keys.sorted(), manifest.files.sorted())
        XCTAssertFalse(manifestText.contains(home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent("state_5.sqlite").path))
    }

    func testRestoreRejectsTamperedBackupArtifact() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"custom\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        let manifest = try service.create(codexHome: home)
        try "tampered\n".write(to: manifest.directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.restore(manifest, to: home))
    }

    func testRestoreRecoversSyntheticConfigAndSQLiteState() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try "model_provider = \"custom\"\n".write(to: config, atomically: true, encoding: .utf8)
        let database = home.appendingPathComponent("state_5.sqlite")
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(connection, "CREATE TABLE threads (id TEXT); INSERT INTO threads VALUES ('fixture-thread');", nil, nil, nil), SQLITE_OK)
        sqlite3_close(connection)

        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        let manifest = try service.create(codexHome: home)
        try "model_provider = \"damaged\"\n".write(to: config, atomically: true, encoding: .utf8)
        try service.restore(manifest, to: home)

        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "model_provider = \"custom\"\n")
        XCTAssertEqual(sha256(try Data(contentsOf: config)), manifest.checksums["config.toml"])
        XCTAssertEqual(sha256(try Data(contentsOf: database)), manifest.checksums["state_5.sqlite"])
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(connection, "SELECT COUNT(*) FROM threads", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 1)
    }

    func testCreateSkipsDirectorySymlinkWhenChecksummingPreservedPluginCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let version = home.appendingPathComponent("plugins/cache/openai-bundled/chrome/26.803.61601")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try "fixture\n".write(to: version.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let latest = version.deletingLastPathComponent().appendingPathComponent("latest")
        try FileManager.default.createSymbolicLink(at: latest, withDestinationURL: version)

        let manifest = try BackupService(backupRoot: home.appendingPathComponent("backups")).create(codexHome: home)

        XCTAssertTrue(manifest.files.contains("preserved/plugins/cache/openai-bundled/chrome/26.803.61601/plugin.json"))
        XCTAssertFalse(manifest.files.contains { $0.hasSuffix("/latest") || $0.contains("/latest/") })
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent("preserved/plugins/cache/openai-bundled/chrome/latest").path))
    }

    func testLatestOpenAIConfigurationBaselineUsesVerifiedBackup() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        try """
        model = "gpt-5.6-terra"
        model_reasoning_effort = "ultra"
        review_model = "gpt-5.5"
        model_provider = "openai"
        """.write(to: config, atomically: true, encoding: .utf8)
        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        _ = try service.create(codexHome: home)
        try "model_provider = \"qilin\"\n".write(to: config, atomically: true, encoding: .utf8)

        XCTAssertEqual(
            service.latestOpenAIConfigurationBaseline(codexHome: home),
            OpenAIConfigurationBaseline(model: "gpt-5.6-terra", reasoningEffort: "ultra", reviewModel: "gpt-5.5")
        )
    }

    /// Preserved roots (sessions/skills/plugins) are snapshotted with an APFS
    /// clone and must not be hashed into the manifest: hashing gigabytes of
    /// rollouts made every switch hang for minutes on a real Codex home.
    func testCreateExcludesPreservedRootsFromChecksumsButKeepsThemInFiles() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"qilin\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let session = home.appendingPathComponent("sessions/2026/08/rollout-fixture.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"type\":\"message\"}\n".write(to: session, atomically: true, encoding: .utf8)

        let manifest = try BackupService(backupRoot: home.appendingPathComponent("backups")).create(codexHome: home)

        XCTAssertTrue(manifest.files.contains("preserved/sessions/2026/08/rollout-fixture.jsonl"))
        XCTAssertNil(manifest.checksums["preserved/sessions/2026/08/rollout-fixture.jsonl"])
        XCTAssertNotNil(manifest.checksums["config.toml"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent("preserved/sessions/2026/08/rollout-fixture.jsonl").path))
    }

    /// Restore replaces preserved roots and verifies them by count/size (fast)
    /// instead of re-hashing every session file.
    func testRestoreReplacesPreservedSessionsAndVerifiesByStats() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"qilin\"\n".write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let session = home.appendingPathComponent("sessions/2026/08/rollout-fixture.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "{\"type\":\"message\"}\n".write(to: session, atomically: true, encoding: .utf8)
        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        let manifest = try service.create(codexHome: home)

        try FileManager.default.removeItem(at: home.appendingPathComponent("sessions"))
        try service.restore(manifest, to: home)

        XCTAssertTrue(FileManager.default.fileExists(atPath: session.path))
        XCTAssertEqual(try String(contentsOf: session, encoding: .utf8), "{\"type\":\"message\"}\n")
    }

    private func makeBackup(_ service: BackupService, at home: URL, label: String, config: String = "model_provider = \"custom\"\n") throws {
        try config.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        _ = try service.create(codexHome: home)
    }

    func testPruneKeepsOnlyNewestFiveBackupsByDefault() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        for _ in 0..<8 { try makeBackup(service, at: home, label: "x") }

        let summaries = try service.backupSummaries(codexHome: home)

        XCTAssertEqual(summaries.count, 5)
        XCTAssertTrue(summaries.allSatisfy { $0.logicalBytes > 0 })
    }

    func testPruneHonorsByteLimitAndEvictsOldestFirst() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        // Tiny byte budget: only the newest backup may survive.
        let service = BackupService(
            backupRoot: home.appendingPathComponent("backups"),
            retentionCount: 10,
            maxBackupBytes: 15_000,
            maxBackupAgeDays: 365
        )
        let payload = String(repeating: "x", count: 10_000) + "\n"
        for _ in 0..<4 { try makeBackup(service, at: home, label: "x", config: payload) }

        let summaries = try service.backupSummaries(codexHome: home)

        XCTAssertEqual(summaries.count, 1)
    }

    func testPruneEvictsExpiredBackupsAndSkipsPinnedOnes() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        try makeBackup(service, at: home, label: "a")
        try makeBackup(service, at: home, label: "b")
        let summaries = try service.backupSummaries(codexHome: home)
        let oldestID = summaries.min { $0.createdAt < $1.createdAt }!.backupID
        let newestID = summaries.max { $0.createdAt < $1.createdAt }!.backupID

        // Age the oldest backup beyond the 14-day default window.
        let root = home.appendingPathComponent("backups")
        let oldestManifest = root.appendingPathComponent(oldestID).appendingPathComponent("manifest.json")
        let decoded = try JSONDecoder().decode(BackupManifest.self, from: Data(contentsOf: oldestManifest))
        let aged = BackupManifest(
            directory: decoded.directory,
            createdAt: Date().addingTimeInterval(-40 * 86_400),
            files: decoded.files,
            checksums: decoded.checksums,
            logicalBytes: decoded.logicalBytes,
            isPinned: decoded.isPinned
        )
        try JSONEncoder().encode(aged).write(to: oldestManifest, options: .atomic)

        try service.setPinned(backupID: oldestID, isPinned: true, codexHome: home)
        try service.pruneNow(codexHome: home)

        let remaining = try service.backupSummaries(codexHome: home).map(\.backupID)
        XCTAssertEqual(Set(remaining), Set([oldestID, newestID]), "pinned expired backup must survive")
        XCTAssertTrue(try service.backupSummaries(codexHome: home).first { $0.backupID == oldestID }?.isPinned == true)

        try service.setPinned(backupID: oldestID, isPinned: false, codexHome: home)
        try service.pruneNow(codexHome: home)
        XCTAssertEqual(try service.backupSummaries(codexHome: home).map(\.backupID), [newestID])
    }

    func testDeleteAndSummariesExposeManagedBackupIDs() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let service = BackupService(backupRoot: home.appendingPathComponent("backups"))
        try makeBackup(service, at: home, label: "a")
        try makeBackup(service, at: home, label: "b")
        let ids = try service.backupSummaries(codexHome: home).map(\.backupID)
        XCTAssertEqual(ids.count, 2)

        try service.delete(backupID: ids[1], codexHome: home)

        XCTAssertEqual(try service.backupSummaries(codexHome: home).map(\.backupID), [ids[0]])
    }

    func testBackupManifestDecodesLegacyFormatWithoutLogicalBytes() throws {
        let legacy = """
        {"directory":"/tmp/legacy","createdAt":708693600,"files":["config.toml"],"checksums":{},"isPinned":false}
        """
        let manifest = try JSONDecoder().decode(BackupManifest.self, from: Data(legacy.utf8))
        XCTAssertEqual(manifest.logicalBytes, 0)
        XCTAssertFalse(manifest.isPinned)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
