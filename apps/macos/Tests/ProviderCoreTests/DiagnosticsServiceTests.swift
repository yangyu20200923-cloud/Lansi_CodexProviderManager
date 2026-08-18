import Foundation
import SQLite3
import XCTest
@testable import ProviderCore

final class DiagnosticsServiceTests: XCTestCase {
    func testActivityDiagnosticsCountSessionsExtensionsAndMCPServers() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try createThreadsDatabase(at: home.appendingPathComponent("state_5.sqlite"), count: 2)
        try write("{}\n", to: home.appendingPathComponent("sessions/2026/one.jsonl"))
        try write("{}\n", to: home.appendingPathComponent("sessions/2026/two.jsonl"))
        try write("skill\n", to: home.appendingPathComponent("skills/one/SKILL.md"))
        try write("skill\n", to: home.appendingPathComponent("skills/two/SKILL.md"))
        try write("{}\n", to: home.appendingPathComponent("plugins/one/plugin.json"))
        try write("{}\n", to: home.appendingPathComponent("mcp/fixture.json"))
        try write("[mcp_servers.one]\ncommand = \"one\"\n[mcp_servers.two]\ncommand = \"two\"\n", to: home.appendingPathComponent("config.toml"))

        let activity = try DiagnosticsService(codexHome: home).inspect().activity

        XCTAssertEqual(activity.threadCount, 2)
        XCTAssertEqual(activity.sessionFileCount, 2)
        XCTAssertEqual(activity.skillCount, 2)
        XCTAssertEqual(activity.pluginCount, 1)
        XCTAssertEqual(activity.mcpServerCount, 2)
        XCTAssertEqual(activity.mcpFileCount, 1)
        XCTAssertNil(activity.historyIssue)
    }

    func testActivityDiagnosticsStillReportsExtensionsWhenThreadDatabaseIsMissingOrIncompatible() throws {
        let home = try makeFixtureHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("skill\n", to: home.appendingPathComponent("skills/one/SKILL.md"))

        let missing = try DiagnosticsService(codexHome: home).inspect().activity

        XCTAssertNil(missing.threadCount)
        XCTAssertEqual(missing.historyIssue, .stateDatabaseMissing)
        XCTAssertEqual(missing.skillCount, 1)

        try createIncompatibleDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        let incompatible = try DiagnosticsService(codexHome: home).inspect().activity
        XCTAssertNil(incompatible.threadCount)
        XCTAssertEqual(incompatible.historyIssue, .threadsUnavailable)
        XCTAssertEqual(incompatible.skillCount, 1)
    }

    private func makeFixtureHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func write(_ value: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try value.write(to: url, atomically: true, encoding: .utf8)
    }

    private func createThreadsDatabase(at url: URL, count: Int) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE threads (id TEXT PRIMARY KEY)", nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
        for index in 0..<count {
            guard sqlite3_exec(database, "INSERT INTO threads VALUES ('thread-\(index)')", nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
        }
    }

    private func createIncompatibleDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else { throw TestError.sqlite }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, "CREATE TABLE unrelated (id TEXT)", nil, nil, nil) == SQLITE_OK else { throw TestError.sqlite }
    }
}

private enum TestError: Error { case sqlite }
