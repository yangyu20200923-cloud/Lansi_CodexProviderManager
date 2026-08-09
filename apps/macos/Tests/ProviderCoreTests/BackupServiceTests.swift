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

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
