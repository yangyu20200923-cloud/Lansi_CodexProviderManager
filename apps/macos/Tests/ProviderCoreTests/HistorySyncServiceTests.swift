import Foundation
import SQLite3
import XCTest
@testable import ProviderCore

final class HistorySyncServiceTests: XCTestCase {
    func testVerifyRejectsExtensionContentMutation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("sessions/2026"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("skills/fixture"), withIntermediateDirectories: true)
        try "{\"type\":\"synthetic\"}\n".write(to: home.appendingPathComponent("sessions/2026/fixture.jsonl"), atomically: true, encoding: .utf8)
        let skill = home.appendingPathComponent("skills/fixture/SKILL.md")
        try "synthetic skill\n".write(to: skill, atomically: true, encoding: .utf8)
        try createDatabase(at: home.appendingPathComponent("state_5.sqlite"))

        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        try "mutated skill\n".write(to: skill, atomically: true, encoding: .utf8)
        let after = try history.snapshot()

        XCTAssertThrowsError(try history.verify(before: before, after: after))
    }

    func testSynchronizeDoesNotRewriteExistingThreadProviderMetadata() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database)

        try HistorySyncService(codexHome: home).synchronize(provider: .qilin)

        XCTAssertEqual(try threadProvider(in: database), "openai")
    }

    private func createDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw TestError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, title TEXT, preview TEXT, archived INTEGER);
        INSERT INTO threads VALUES ('one', 'openai', 'Synthetic', '', 0);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
    }

    private func threadProvider(in url: URL) throws -> String? {
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw TestError.sqlite
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT model_provider FROM threads WHERE id = 'one'", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0) else {
            throw TestError.sqlite
        }
        return String(cString: value)
    }
}

private enum TestError: Error { case sqlite }
