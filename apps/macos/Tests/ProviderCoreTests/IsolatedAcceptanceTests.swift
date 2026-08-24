import Foundation
import SQLite3
import XCTest
@testable import ProviderCore

private struct StubModelFetcher: ModelListFetching {
    let result: Result<[String], ModelCatalogError>

    func fetch(baseURL: String, apiKey: String) async throws -> [String] {
        try result.get()
    }
}

final class IsolatedAcceptanceTests: XCTestCase {
    private static func offlineFetcher() -> StubModelFetcher {
        StubModelFetcher(result: .failure(.invalidResponse))
    }

    func testIsolatedConfigurationRejectsNonTemporaryPaths() throws {
        let temporaryStore = FileManager.default.temporaryDirectory.appendingPathComponent("profiles.json")

        XCTAssertThrowsError(
            try IsolatedAcceptanceConfiguration(
                codexHome: URL(fileURLWithPath: "/Users/example/.codex"),
                profileStoreURL: temporaryStore
            )
        )
    }

    func testIsolatedConfigurationAcceptsTemporaryHomeAndStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let configuration = try IsolatedAcceptanceConfiguration(
            codexHome: root.appendingPathComponent("codex-home"),
            profileStoreURL: root.appendingPathComponent("state/profiles.json")
        )

        XCTAssertEqual(configuration.codexHome, root.appendingPathComponent("codex-home"))
        XCTAssertEqual(configuration.profileStoreURL, root.appendingPathComponent("state/profiles.json"))
    }

    func testProductionFactoriesKeepSystemControllers() {
        XCTAssertTrue(ProviderRuntimeControllers.production() is ChatGPTService)
        XCTAssertTrue(ProviderCredentialStores.production() is KeychainService)
    }

    func testIsolatedControllerPreservesFixtureConversationsAndExtensionsDuringSwitch() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        model_provider = "openai"
        [features]
        project_state = true
        [mcp_servers.fixture]
        command = "fixture-mcp"
        """.write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()

        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        let runtime = ProviderRuntimeControllers.isolatedAcceptance()
        let baselineStore = OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json"))

        let result = await ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: runtime,
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: baselineStore,
            modelFetcher: Self.offlineFetcher()
        ).apply(target: profile, availableProfiles: ProviderDefaults.all + [profile])

        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(
            runtime.recordedOperations,
            [.quit, .waitUntilQuiescent, .setEnvironment(profile.id), .verifyConfiguration(profile.configProviderID), .launch, .verifyLaunchedRuntime(profile.id)]
        )
        XCTAssertEqual(try credentials.read(provider: profile.id), "fixture-key")
        XCTAssertTrue((try String(contentsOf: home.appendingPathComponent("config.toml"))).contains(profile.configProviderID))
        try history.verifySwitched(
            before: before,
            after: try history.snapshot(),
            provider: profile.configProviderID,
            model: profile.model,
            reasoningEffort: profile.reasoningEffort
        )
        XCTAssertEqual(try threadProvider(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread"), profile.configProviderID)
        XCTAssertEqual(try threadProvider(in: home.appendingPathComponent("state_5.sqlite"), id: "existing-custom"), profile.configProviderID)
        XCTAssertEqual(try threadValue(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread", column: "model"), profile.model)
        XCTAssertEqual(try threadValue(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread", column: "reasoning_effort"), profile.reasoningEffort)
        let session = try String(contentsOf: home.appendingPathComponent("sessions/2026/fixture.jsonl"), encoding: .utf8)
        XCTAssertTrue(session.contains("\"model_provider\":\"\(profile.configProviderID)\""))
    }

    /// The switch reports each phase through the callback so the UI can show
    /// live progress instead of looking frozen while the environment is
    /// snapshotted and verified.
    func testSwitchReportsPhaseProgressThroughCallback() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"openai\"\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        var phases: [SwitchPhase] = []
        let phaseLock = NSLock()

        let result = await ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: ProviderRuntimeControllers.isolatedAcceptance(),
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: Self.offlineFetcher()
        ).apply(
            target: profile,
            availableProfiles: ProviderDefaults.all + [profile],
            onPhase: { phase, _ in
                phaseLock.lock()
                phases.append(phase)
                phaseLock.unlock()
            }
        )

        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertEqual(Set(phases), [.quitting, .backingUp, .verifying, .launching])
        XCTAssertEqual(phases.first, .quitting)
        XCTAssertEqual(phases.last, .launching)
    }

    func testSwitchNormalizesPollutedSessionReasoningContent() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"openai\"\n".write(
            to: home.appendingPathComponent("config.toml"),
            atomically: true,
            encoding: .utf8
        )
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let polluted = home.appendingPathComponent("sessions/2026/deepseek-polluted.jsonl")
        try """
        {"type":"session_meta","payload":{"id":"deepseek-thread","session_id":"deepseek-thread","model_provider":"custom_deepseek","cwd":"/tmp"}}
        {"type":"response_item","payload":{"type":"reasoning","id":"r1","summary":[],"content":[{"type":"reasoning_text","text":"plaintext thinking"}],"encrypted_content":"c2VjcmV0"}}
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}
        """.write(to: polluted, atomically: true, encoding: .utf8)
        let originalLineCount = try String(contentsOf: polluted, encoding: .utf8)
            .components(separatedBy: "\n").count

        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        let result = await ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: ProviderRuntimeControllers.isolatedAcceptance(),
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: Self.offlineFetcher()
        ).apply(target: profile, availableProfiles: ProviderDefaults.all + [profile])

        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertTrue(result.message.contains("reasoning entries"), result.message)
        let lines = try String(contentsOf: polluted, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, originalLineCount)
        XCTAssertTrue(lines[0].contains("\"model_provider\":\"\(profile.configProviderID)\""))
        XCTAssertTrue(lines[1].contains("\"content\":[]"))
        XCTAssertTrue(lines[1].contains("\"encrypted_content\":null"))
        XCTAssertFalse(lines[1].contains("plaintext thinking"))
        XCTAssertTrue(lines[2].contains("\"output_text\""))
        let switchLog = try String(contentsOf: home.appendingPathComponent("state/switch.log"), encoding: .utf8)
        XCTAssertTrue(switchLog.contains("switch start"), switchLog)
        XCTAssertTrue(switchLog.contains("runtime launch verified"), switchLog)
        XCTAssertTrue(switchLog.contains("switch complete"), switchLog)
    }

    func testSwitchBackToOpenAIRestoresSavedRootConfiguration() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try """
        model = "gpt-5.6-terra"
        model_reasoning_effort = "ultra"
        review_model = "gpt-5.5"
        model_provider = "openai"
        [features]
        project_state = true
        """.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)

        let qilin = ProviderDefaults.profile(for: .qilin)
        let openAI = ProviderDefaults.profile(for: .openAI)
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: qilin.id)
        let baselineStore = OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json"))
        let coordinator = ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: ProviderRuntimeControllers.isolatedAcceptance(),
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: baselineStore,
            modelFetcher: Self.offlineFetcher()
        )

        let thirdPartyResult = await coordinator.apply(target: qilin, availableProfiles: [openAI, qilin])
        XCTAssertTrue(thirdPartyResult.succeeded, thirdPartyResult.message)
        XCTAssertTrue((try String(contentsOf: home.appendingPathComponent("config.toml"))).contains("model = \"gpt-5.5\""))
        XCTAssertEqual(
            try baselineStore.load(),
            OpenAIConfigurationBaseline(model: "gpt-5.6-terra", reasoningEffort: "ultra", reviewModel: "gpt-5.5")
        )

        let openAIResult = await coordinator.apply(target: openAI, availableProfiles: [openAI, qilin])
        XCTAssertTrue(openAIResult.succeeded, openAIResult.message)
        let restored = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertTrue(restored.contains("model = \"gpt-5.6-terra\""))
        XCTAssertTrue(restored.contains("model_reasoning_effort = \"ultra\""))
        XCTAssertTrue(restored.contains("review_model = \"gpt-5.5\""))
        XCTAssertTrue(restored.contains("model_provider = \"openai\""))
        XCTAssertTrue(restored.contains("project_state = true"))
        XCTAssertEqual(try threadValue(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread", column: "model"), "gpt-5.6-terra")
        XCTAssertEqual(try threadValue(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread", column: "reasoning_effort"), "ultra")
    }

    func testSwitchWritesGPTNamedManagedModelsWithoutInjectingUpstreamCatalog() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "model_provider = \"openai\"\n".write(
            to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        var qilin = ProviderDefaults.profile(for: .qilin)
        // The user explicitly managed a small list; the upstream catalog must
        // not be injected into it.
        qilin.models = ["gpt-5.5", "gpt-5.6-sol"]
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: qilin.id)
        let coordinator = ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: ProviderRuntimeControllers.isolatedAcceptance(),
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: StubModelFetcher(result: .success(["gpt-5.5", "gpt-5.6-sol", "gpt-5.6-terra"]))
        )

        let result = await coordinator.apply(target: qilin, availableProfiles: [ProviderDefaults.profile(for: .openAI), qilin])

        XCTAssertTrue(result.succeeded, result.message)
        XCTAssertFalse(result.message.contains("full provider model list"), result.message)
        let config = try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: home)
        XCTAssertTrue(config.contains("model_catalog_json = \"\(catalogURL.path)\""))
        let rendered = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let slugs = (rendered?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String }
        // Only the user-managed list is written; upstream extras stay out.
        XCTAssertEqual(slugs, ["gpt-5.5", "gpt-5.6-sol"])
    }

    func testIsolatedFailureRestoresFixtureConversationsAndExtensions() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let config = home.appendingPathComponent("config.toml")
        let originalConfig = "model_provider = \"openai\"\n[mcp_servers.fixture]\ncommand = \"fixture-mcp\"\n"
        try originalConfig.write(to: config, atomically: true, encoding: .utf8)
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()

        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        let result = await ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: FixtureMutatingFailureRuntime(codexHome: home),
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: Self.offlineFetcher()
        ).apply(target: profile, availableProfiles: ProviderDefaults.all + [profile])

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.phase, .recovering)
        XCTAssertTrue(result.message.contains("previous state was restored"), result.message)
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), originalConfig)
        XCTAssertEqual(try history.snapshot(), before)
        XCTAssertEqual(try threadProvider(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread"), "openai")
        let restoredSession = try String(contentsOf: home.appendingPathComponent("sessions/2026/fixture.jsonl"), encoding: .utf8)
        XCTAssertTrue(restoredSession.contains("\"model_provider\":\"openai\""))
    }

    func testPostLaunchFailureQuiescesTheTargetRuntimeBeforeRestoring() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let originalConfig = "model_provider = \"openai\"\n"
        try originalConfig.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        let runtime = PostLaunchFailureRuntime()
        let result = await ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: runtime,
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: Self.offlineFetcher()
        ).apply(target: profile, availableProfiles: ProviderDefaults.all + [profile])

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.phase, .recovering)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8), originalConfig)
        XCTAssertEqual(
            runtime.recordedOperations,
            [
                .quit, .waitUntilQuiescent, .setEnvironment(profile.id), .verifyConfiguration(profile.configProviderID), .launch, .verifyLaunchedRuntime(profile.id),
                .quit, .waitUntilQuiescent, .setEnvironment(.openAI), .verifyConfiguration("openai"), .launch, .verifyLaunchedRuntime(.openAI)
            ]
        )
    }

    func testIsolatedControllerRestoresLatestBackupWithoutChangingFixtureHistory() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let originalConfig = "model_provider = \"openai\"\n[mcp_servers.fixture]\ncommand = \"fixture-mcp\"\n"
        try originalConfig.write(to: home.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        try createHistoryDatabase(at: home.appendingPathComponent("state_5.sqlite"))
        try createPreservedFixture(at: home)
        let history = HistorySyncService(codexHome: home)
        let before = try history.snapshot()
        let profile = fixtureProfile()
        let credentials = ProviderCredentialStores.isolatedAcceptance()
        try credentials.write(key: "fixture-key", for: profile.id)
        let runtime = ProviderRuntimeControllers.isolatedAcceptance()
        let coordinator = ProviderSwitchCoordinator(
            codexHome: home,
            keychain: credentials,
            chatGPT: runtime,
            backupService: BackupService(backupRoot: home.appendingPathComponent("backups")),
            openAIBaselineStore: OpenAIConfigurationBaselineStore(fileURL: home.appendingPathComponent("state/openai-baseline.json")),
            modelFetcher: Self.offlineFetcher()
        )

        let switched = await coordinator.apply(target: profile, availableProfiles: ProviderDefaults.all + [profile])
        XCTAssertTrue(switched.succeeded, switched.message)
        let restored = await coordinator.restoreLatest(availableProfiles: ProviderDefaults.all + [profile])

        XCTAssertTrue(restored.succeeded, restored.message)
        XCTAssertEqual(restored.phase, .complete)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("config.toml")), originalConfig)
        XCTAssertEqual(try history.snapshot(), before)
        XCTAssertEqual(try threadProvider(in: home.appendingPathComponent("state_5.sqlite"), id: "fixture-thread"), "openai")
        let restoredSession = try String(contentsOf: home.appendingPathComponent("sessions/2026/fixture.jsonl"), encoding: .utf8)
        XCTAssertTrue(restoredSession.contains("\"model_provider\":\"openai\""))
        XCTAssertEqual(
            runtime.recordedOperations,
            [.quit, .waitUntilQuiescent, .setEnvironment(profile.id), .verifyConfiguration(profile.configProviderID), .launch, .verifyLaunchedRuntime(profile.id), .quit, .waitUntilQuiescent, .setEnvironment(.openAI), .verifyConfiguration("openai"), .launch, .verifyLaunchedRuntime(.openAI)]
        )
    }

    private func createHistoryDatabase(at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK, let database else {
            throw NSError(domain: "IsolatedAcceptanceTests", code: 1)
        }
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE threads (id TEXT PRIMARY KEY, model_provider TEXT, model TEXT, reasoning_effort TEXT, title TEXT, preview TEXT, archived INTEGER);
        INSERT INTO threads (id, model_provider, model, reasoning_effort, title, preview, archived) VALUES ('fixture-thread', 'openai', 'gpt-5.6-terra', 'ultra', 'Fixture', '', 0);
        INSERT INTO threads (id, model_provider, model, reasoning_effort, title, preview, archived) VALUES ('existing-custom', 'custom_fixture', 'gpt-5.6-sol', 'high', 'Existing custom', '', 0);
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "IsolatedAcceptanceTests", code: 2)
        }
    }

    private func createPreservedFixture(at home: URL) throws {
        for (path, content) in [
            ("sessions/2026/fixture.jsonl", "{\"type\":\"session_meta\",\"payload\":{\"id\":\"fixture-thread\",\"session_id\":\"fixture-thread\",\"model_provider\":\"openai\",\"cwd\":\"/tmp\"}}\n{\"type\":\"synthetic\"}\n"),
            ("skills/fixture/SKILL.md", "fixture skill\n"),
            ("plugins/fixture/plugin.json", "{\"name\":\"fixture\"}\n"),
            ("mcp/fixture.json", "{\"command\":\"fixture\"}\n")
        ] {
            let file = home.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try content.write(to: file, atomically: true, encoding: .utf8)
        }
    }

    private func fixtureProfile() -> ProviderProfile {
        ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Fixture Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "FIXTURE_PROVIDER_API_KEY",
            model: "fixture-model",
            reasoningEffort: "high",
            isBuiltIn: false
        )
    }

    private func threadProvider(in databaseURL: URL, id: String) throws -> String? {
        try threadValue(in: databaseURL, id: id, column: "model_provider")
    }

    private func threadValue(in databaseURL: URL, id: String, column: String) throws -> String? {
        guard ["model_provider", "model", "reasoning_effort"].contains(column) else {
            throw NSError(domain: "IsolatedAcceptanceTests", code: 4)
        }
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database else {
            throw NSError(domain: "IsolatedAcceptanceTests", code: 3)
        }
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "SELECT \(column) FROM threads WHERE id = ?", -1, &statement, nil) == SQLITE_OK else {
            throw NSError(domain: "IsolatedAcceptanceTests", code: 4)
        }
        sqlite3_bind_text(statement, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_text(statement, 0).map { String(cString: $0) }
    }
}

private final class FixtureMutatingFailureRuntime: ProviderRuntimeControlling, @unchecked Sendable {
    private let codexHome: URL
    private var shouldFail = true

    init(codexHome: URL) { self.codexHome = codexHome }

    func quit() async throws {}
    func waitUntilQuiescent(timeout _: TimeInterval) async throws {}
    func launch() async throws {}

    func setEnvironment(profile _: ProviderProfile, key _: String?) throws {
        guard shouldFail else { return }
        shouldFail = false
        try "mutated skill\n".write(
            to: codexHome.appendingPathComponent("skills/fixture/SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.removeItem(at: codexHome.appendingPathComponent("plugins/fixture/plugin.json"))
        try "{\"command\":\"unexpected\"}\n".write(
            to: codexHome.appendingPathComponent("mcp/unexpected.json"),
            atomically: true,
            encoding: .utf8
        )
        throw FixtureFailure.expected
    }

    func verifyConfiguration(codexHome _: URL, profile _: ProviderProfile, key _: String?) throws {}
    func verifyLaunchedRuntime(profile _: ProviderProfile) async throws {}
}

private enum FixtureFailure: Error { case expected }

private final class PostLaunchFailureRuntime: ProviderRuntimeControlling, @unchecked Sendable {
    private(set) var recordedOperations: [ProviderRuntimeOperation] = []
    private var shouldFailVerification = true

    func quit() async throws { recordedOperations.append(.quit) }
    func waitUntilQuiescent(timeout _: TimeInterval) async throws { recordedOperations.append(.waitUntilQuiescent) }
    func launch() async throws { recordedOperations.append(.launch) }
    func setEnvironment(profile: ProviderProfile, key _: String?) throws { recordedOperations.append(.setEnvironment(profile.id)) }
    func verifyConfiguration(codexHome _: URL, profile: ProviderProfile, key _: String?) throws {
        recordedOperations.append(.verifyConfiguration(profile.configProviderID))
    }
    func verifyLaunchedRuntime(profile: ProviderProfile) async throws {
        recordedOperations.append(.verifyLaunchedRuntime(profile.id))
        if shouldFailVerification {
            shouldFailVerification = false
            throw FixtureFailure.expected
        }
    }
}
