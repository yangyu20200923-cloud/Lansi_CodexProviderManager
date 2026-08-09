import Foundation
import SQLite3
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
        XCTAssertFalse(manifestText.contains(home.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.directory.appendingPathComponent("state_5.sqlite").path))
    }
}
