import Foundation
import ProviderCore
import SQLite3

@main
struct IntegrationProbe {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("CodexProviderManagerProbe-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appendingPathComponent("sessions/26/08"), withIntermediateDirectories: true)
        for directory in ["skills", "plugins"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }

        let config = """
        model = "gpt-5.6-sol"
        model_provider = "openai"
        [features]
        goals = true
        [mcp_servers.example]
        command = "example"

        """
        try config.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sessionURL = root.appendingPathComponent("sessions/26/08/rollout.jsonl")
        let sessionBytes = Data("{\"event\":\"test\"}\n".utf8)
        try sessionBytes.write(to: sessionURL)
        try createDatabase(at: root.appendingPathComponent("state_5.sqlite"))

        let history = HistorySyncService(codexHome: root)
        let before = try history.snapshot()
        precondition(before.totalThreads == 1 && before.visibleThreads == 0)
        precondition(before.extensionPaths == Set(["skills", "plugins", "mcp"]))
        let backup = try BackupService(backupRoot: root.appendingPathComponent("probe-backups")).create(codexHome: root)

        let vector = ProviderDefaults.profile(for: .vectorEngine)
        try CodexConfigService().apply(profile: vector, to: root.appendingPathComponent("config.toml"))
        try history.synchronize(provider: .vectorEngine)
        let after = try history.snapshot()
        try history.verify(before: before, after: after)
        precondition(after.visibleThreads == 1)
        let switchedSessionBytes = try Data(contentsOf: sessionURL)
        precondition(switchedSessionBytes == sessionBytes)
        let updatedConfig = try String(contentsOf: root.appendingPathComponent("config.toml"))
        precondition(updatedConfig.contains("model_provider = \"vectorengine\""))
        precondition(updatedConfig.contains("base_url = \"https://api.vectorengine.cn/v1\""))
        precondition(updatedConfig.contains("env_key = \"VECTORENGINE_API_KEY\""))
        precondition(updatedConfig.contains("goals = true"))

        try BackupService(backupRoot: root.appendingPathComponent("probe-backups")).restore(backup, to: root)
        let restoredConfig = try String(contentsOf: root.appendingPathComponent("config.toml"))
        precondition(restoredConfig == config)
        let restoredProvider = try providerValue(at: root.appendingPathComponent("state_5.sqlite"))
        let restoredSessionBytes = try Data(contentsOf: sessionURL)
        precondition(restoredProvider == "openai")
        precondition(restoredSessionBytes == sessionBytes)
        print("Integration probe passed")
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw ProbeError.sqlite }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, title TEXT NOT NULL, preview TEXT NOT NULL DEFAULT '', archived INTEGER NOT NULL DEFAULT 0);
        INSERT INTO threads(id, model_provider, title, preview, archived) VALUES('one', 'openai', 'Visible title', '', 0);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ProbeError.sqlite }
    }

    private static func providerValue(at url: URL) throws -> String {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw ProbeError.sqlite }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT model_provider FROM threads LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { throw ProbeError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else { throw ProbeError.sqlite }
        return String(cString: value)
    }
}

enum ProbeError: Error { case sqlite }
