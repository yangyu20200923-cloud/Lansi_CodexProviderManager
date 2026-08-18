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
        for directory in ["skills/fixture", "plugins/fixture", "mcp"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }

        let config = """
        model = "gpt-5.6-sol"
        model_reasoning_effort = "ultra"
        model_provider = "openai"
        [features]
        goals = true
        [mcp_servers.example]
        command = "example"

        """
        try config.write(to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let sessionURL = root.appendingPathComponent("sessions/26/08/rollout.jsonl")
        let sessionLines = [
            "{\"event\":\"test\"}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"reasoning\",\"id\":\"r1\",\"summary\":[],\"content\":[{\"type\":\"reasoning_text\",\"text\":\"plaintext thinking\"}],\"encrypted_content\":\"c2VjcmV0\"}}",
            "{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"answer\"}]}}",
        ]
        let sessionBytes = Data((sessionLines.joined(separator: "\n") + "\n").utf8)
        try sessionBytes.write(to: sessionURL)
        let skillURL = root.appendingPathComponent("skills/fixture/SKILL.md")
        let skillBytes = Data("---\nname: fixture-skill\n---\nFixture skill.\n".utf8)
        try skillBytes.write(to: skillURL)
        let pluginURL = root.appendingPathComponent("plugins/fixture/plugin.json")
        let pluginBytes = Data("{\"name\":\"fixture-plugin\"}\n".utf8)
        try pluginBytes.write(to: pluginURL)
        let mcpURL = root.appendingPathComponent("mcp/fixture.json")
        let mcpBytes = Data("{\"name\":\"fixture-mcp\"}\n".utf8)
        try mcpBytes.write(to: mcpURL)
        try createDatabase(at: root.appendingPathComponent("state_5.sqlite"))

        let history = HistorySyncService(codexHome: root)
        let compat = try SessionCompatService(codexHome: root).normalizeReasoningContent()
        precondition(compat.normalizedFiles == 1 && compat.normalizedItems == 1)
        let normalizedSessionBytes = try Data(contentsOf: sessionURL)
        precondition(!String(data: normalizedSessionBytes, encoding: .utf8)!.contains("plaintext thinking"))
        precondition(String(data: normalizedSessionBytes, encoding: .utf8)!.components(separatedBy: "\n").count == 4)
        let before = try history.snapshot()
        precondition(before.totalThreads == 1 && before.visibleThreads == 0)
        precondition(before.extensionPaths == Set(["skills", "plugins", "mcp"]))
        let backup = try BackupService(backupRoot: root.appendingPathComponent("probe-backups")).create(codexHome: root)

        let fixture = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Fixture Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "FIXTURE_PROVIDER_API_KEY",
            model: "fixture-model",
            reasoningEffort: "high",
            isBuiltIn: false
        )
        try CodexConfigService().apply(
            profile: fixture,
            to: root.appendingPathComponent("config.toml"),
            managesModelCatalog: true
        )
        try history.synchronize(
            provider: fixture.configProviderID,
            model: fixture.model,
            reasoningEffort: fixture.reasoningEffort
        )
        let after = try history.snapshot()
        let databaseURL = root.appendingPathComponent("state_5.sqlite")
        let switchedProvider = try threadValue(at: databaseURL, column: "model_provider")
        let switchedModel = try threadValue(at: databaseURL, column: "model")
        let switchedReasoningEffort = try threadValue(at: databaseURL, column: "reasoning_effort")
        let switchedSessionBytes = try Data(contentsOf: sessionURL)
        let switchedSkillBytes = try Data(contentsOf: skillURL)
        let switchedPluginBytes = try Data(contentsOf: pluginURL)
        let switchedMCPBytes = try Data(contentsOf: mcpURL)
        try history.verifySwitched(
            before: before,
            after: after,
            provider: fixture.configProviderID,
            model: fixture.model,
            reasoningEffort: fixture.reasoningEffort
        )
        precondition(after.visibleThreads == 0)
        precondition(switchedProvider == fixture.configProviderID)
        precondition(switchedModel == fixture.model)
        precondition(switchedReasoningEffort == fixture.reasoningEffort)
        precondition(switchedSessionBytes == normalizedSessionBytes)
        precondition(switchedSkillBytes == skillBytes)
        precondition(switchedPluginBytes == pluginBytes)
        precondition(switchedMCPBytes == mcpBytes)
        let updatedConfig = try String(contentsOf: root.appendingPathComponent("config.toml"))
        precondition(updatedConfig.contains("model_provider = \"\(fixture.configProviderID)\""))
        precondition(updatedConfig.contains("base_url = \"https://api.example.invalid/v1\""))
        precondition(updatedConfig.contains("env_key = \"FIXTURE_PROVIDER_API_KEY\""))
        precondition(updatedConfig.contains("goals = true"))
        precondition(updatedConfig.contains("[mcp_servers.example]"))
        precondition(updatedConfig.contains("command = \"example\""))
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: root)
        precondition(updatedConfig.contains("model_catalog_json = \"\(catalogURL.path)\""))
        precondition(fileManager.fileExists(atPath: catalogURL.path))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let catalogModels = catalog?["models"] as? [[String: Any]]
        precondition(catalogModels?.contains { $0["slug"] as? String == "fixture-model" } == true)

        try Data("mutated\n".utf8).write(to: skillURL)
        try fileManager.removeItem(at: pluginURL)
        let extraMCPURL = root.appendingPathComponent("mcp/unexpected.json")
        try Data("{\"unexpected\":true}\n".utf8).write(to: extraMCPURL)

        try BackupService(backupRoot: root.appendingPathComponent("probe-backups")).restore(backup, to: root)
        let restoredConfig = try String(contentsOf: root.appendingPathComponent("config.toml"))
        let restored = try history.snapshot()
        let restoredSessionBytes = try Data(contentsOf: sessionURL)
        let restoredSkillBytes = try Data(contentsOf: skillURL)
        let restoredPluginBytes = try Data(contentsOf: pluginURL)
        let restoredMCPBytes = try Data(contentsOf: mcpURL)
        try history.verify(before: before, after: restored)
        precondition(restoredConfig == config)
        let restoredProvider = try threadValue(at: databaseURL, column: "model_provider")
        let restoredModel = try threadValue(at: databaseURL, column: "model")
        let restoredReasoningEffort = try threadValue(at: databaseURL, column: "reasoning_effort")
        precondition(restoredProvider == "openai")
        precondition(restoredModel == "gpt-5.6-sol")
        precondition(restoredReasoningEffort == "ultra")
        precondition(restoredSessionBytes == normalizedSessionBytes)
        precondition(restoredSkillBytes == skillBytes)
        precondition(restoredPluginBytes == pluginBytes)
        precondition(restoredMCPBytes == mcpBytes)
        precondition(!fileManager.fileExists(atPath: extraMCPURL.path))
        print("Integration probe passed")
    }

    private static func createDatabase(at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw ProbeError.sqlite }
        defer { sqlite3_close(db) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL, model TEXT, reasoning_effort TEXT, title TEXT NOT NULL, preview TEXT NOT NULL DEFAULT '', archived INTEGER NOT NULL DEFAULT 0);
        INSERT INTO threads(id, model_provider, model, reasoning_effort, title, preview, archived) VALUES('one', 'openai', 'gpt-5.6-sol', 'ultra', 'Visible title', '', 0);
        """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw ProbeError.sqlite }
    }

    private static func threadValue(at url: URL, column: String) throws -> String? {
        guard ["model_provider", "model", "reasoning_effort"].contains(column) else { throw ProbeError.sqlite }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw ProbeError.sqlite }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT \(column) FROM threads LIMIT 1", -1, &statement, nil) == SQLITE_OK, let statement else { throw ProbeError.sqlite }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw ProbeError.sqlite }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}

enum ProbeError: Error { case sqlite }
