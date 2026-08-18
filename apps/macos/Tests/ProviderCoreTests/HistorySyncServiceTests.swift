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

    func testSnapshotSkipsDirectorySymlinkInsidePluginCache() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let version = home.appendingPathComponent("plugins/cache/openai-bundled/chrome/26.803.61601")
        try FileManager.default.createDirectory(at: version, withIntermediateDirectories: true)
        try "fixture\n".write(to: version.appendingPathComponent("plugin.json"), atomically: true, encoding: .utf8)
        let latest = version.deletingLastPathComponent().appendingPathComponent("latest")
        try FileManager.default.createSymbolicLink(at: latest, withDestinationURL: version)
        try createDatabase(at: home.appendingPathComponent("state_5.sqlite"))

        let snapshot = try HistorySyncService(codexHome: home).snapshot()

        XCTAssertNotNil(snapshot.extensionHashes["plugins/cache/openai-bundled/chrome/26.803.61601/plugin.json"])
        XCTAssertFalse(snapshot.extensionHashes.keys.contains { $0.contains("/latest/") })
    }

    func testSynchronizeRoutesRuntimeSettingsOnlyForUnarchivedThreads() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database)

        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        XCTAssertEqual(
            try history.synchronize(provider: "deepseek", model: "deepseek-v4-pro", reasoningEffort: "high"),
            1
        )
        let after = try history.snapshot()

        try history.verifySwitched(
            before: before,
            after: after,
            provider: "deepseek",
            model: "deepseek-v4-pro",
            reasoningEffort: "high"
        )
        XCTAssertEqual(try threadValue(in: database, id: "one", column: "model_provider"), "deepseek")
        XCTAssertEqual(try threadValue(in: database, id: "one", column: "model"), "deepseek-v4-pro")
        XCTAssertEqual(try threadValue(in: database, id: "one", column: "reasoning_effort"), "high")
        XCTAssertEqual(try threadProvider(in: database, id: "archived"), "openai")
        XCTAssertEqual(try threadValue(in: database, id: "archived", column: "model"), "gpt-5.6-terra")
        XCTAssertEqual(try threadValue(in: database, id: "archived", column: "reasoning_effort"), "ultra")
    }

    func testSynchronizeSupportsLegacyThreadSchemaWithoutModelColumns() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database, includesRuntimeSettings: false)

        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        XCTAssertEqual(
            try history.synchronize(provider: "deepseek", model: "deepseek-v4-pro", reasoningEffort: "high"),
            1
        )

        try history.verifySwitched(
            before: before,
            after: history.snapshot(),
            provider: "deepseek",
            model: "deepseek-v4-pro",
            reasoningEffort: "high"
        )
        XCTAssertEqual(try threadProvider(in: database, id: "one"), "deepseek")
    }

    func testSynchronizeConversationMetadataUpdatesSessionMetaProviderWithoutChangingOtherLines() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let session = home.appendingPathComponent("sessions/2026/fixture.jsonl")
        try FileManager.default.createDirectory(at: session.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = """
        {"type":"session_meta","payload":{"session_id":"fixture","id":"fixture","model_provider":"openai","cwd":"/tmp"}}
        {"type":"synthetic","summary":"preserve this"}
        """
        try original.write(to: session, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try createDatabase(at: home.appendingPathComponent("state_5.sqlite"))

        let history = HistorySyncService(codexHome: home)
        _ = try history.synchronizeConversationMetadata(
            provider: "custom_provider",
            model: "qwen3-coder",
            reasoningEffort: "high"
        )

        let updated = try String(contentsOf: session, encoding: .utf8)
        let firstLine = try XCTUnwrap(updated.split(separator: "\n", omittingEmptySubsequences: true).first)
        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(firstLine.utf8)) as? [String: Any])
        let payload = try XCTUnwrap(firstObject["payload"] as? [String: Any])
        XCTAssertEqual(payload["model_provider"] as? String, "custom_provider")
        XCTAssertNil(firstObject["model_provider"] as? String)
        XCTAssertTrue(updated.contains("\"summary\":\"preserve this\""))
        XCTAssertFalse(updated.contains("\"model_provider\":\"openai\""))
        XCTAssertNoThrow(try SessionMetadataSyncService(codexHome: home).verify(provider: "custom_provider"))
    }

    func testVerifySwitchedRejectsActiveThreadModelMismatch() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database)
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        _ = try history.synchronize(provider: "deepseek", model: "deepseek-v4-pro", reasoningEffort: "high")
        let after = try history.snapshot()

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE threads SET model = 'gpt-5.6-terra' WHERE id = 'one'", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(
            try history.verifySwitched(
                before: before,
                after: after,
                provider: "deepseek",
                model: "deepseek-v4-pro",
                reasoningEffort: "high"
            )
        )
    }

    func testVerifyRejectsThreadRoutingMutation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let database = home.appendingPathComponent("state_5.sqlite")
        try createDatabase(at: database)
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()

        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE threads SET model_provider = 'other' WHERE id = 'one'", nil, nil, nil), SQLITE_OK)

        XCTAssertThrowsError(try history.verify(before: before, after: history.snapshot()))
    }

    func testVerifyRejectsMCPConfigurationMutation() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"openai\"\n[mcp_servers.fixture]\ncommand = \"fixture\"\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try createDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        try "model_provider = \"openai\"\n[mcp_servers.fixture]\ncommand = \"mutated\"\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )

        XCTAssertThrowsError(try history.verify(before: before, after: history.snapshot()))
    }

    private func createDatabase(at url: URL, includesRuntimeSettings: Bool = true) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw TestError.sqlite
        }
        defer { sqlite3_close(database) }
        let sql: String
        if includesRuntimeSettings {
            sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, model TEXT, reasoning_effort TEXT, title TEXT, preview TEXT, archived INTEGER);
            INSERT INTO threads (id, model_provider, model, reasoning_effort, title, preview, archived) VALUES ('one', 'openai', 'gpt-5.6-terra', 'ultra', 'Synthetic', '', 0);
            INSERT INTO threads (id, model_provider, model, reasoning_effort, title, preview, archived) VALUES ('archived', 'openai', 'gpt-5.6-terra', 'ultra', 'Archived', '', 1);
            """
        } else {
            sql = """
            CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, title TEXT, preview TEXT, archived INTEGER);
            INSERT INTO threads VALUES ('one', 'openai', 'Synthetic', '', 0);
            INSERT INTO threads VALUES ('archived', 'openai', 'Archived', '', 1);
            """
        }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
    }

    private func threadProvider(in url: URL, id: String) throws -> String? {
        try threadValue(in: url, id: id, column: "model_provider")
    }

    private func threadValue(in url: URL, id: String, column: String) throws -> String? {
        guard ["model_provider", "model", "reasoning_effort"].contains(column) else { throw TestError.sqlite }
        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw TestError.sqlite
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT \(column) FROM threads WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw TestError.sqlite
        }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw TestError.sqlite }
        return String(cString: value)
    }
}

private enum TestError: Error { case sqlite }
