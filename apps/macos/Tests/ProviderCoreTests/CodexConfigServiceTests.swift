import Foundation
import XCTest
@testable import ProviderCore

final class CodexConfigServiceTests: XCTestCase {
    func testProviderUpdatePreservesUnrelatedConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        let original = "model = \"gpt-5.6-sol\"\nmodel_provider = \"openai\"\n[features]\ngoals = true\n[model_providers.qilin]\nname = \"Qilin\"\nbase_url = \"https://www.qilinapi.com\"\nwire_api = \"responses\"\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        try CodexConfigService().apply(profile: ProviderDefaults.profile(for: .qilin), to: url)
        let result = try String(contentsOf: url)
        XCTAssertTrue(result.contains("model = \"gpt-5.5\""))
        XCTAssertTrue(result.contains("model_provider = \"qilin\""))
        XCTAssertTrue(result.contains("goals = true"))
    }

    func testCustomProviderRendersOnlyItsDedicatedNonSecretConfiguration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n[features]\ngoals = true\n".write(to: url, atomically: true, encoding: .utf8)
        let profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Example Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "EXAMPLE_PROVIDER_API_KEY",
            model: "example-model",
            isBuiltIn: false
        )

        try CodexConfigService().apply(profile: profile, to: url)

        let result = try String(contentsOf: url)
        XCTAssertTrue(result.contains("model_provider = \"\(profile.configProviderID)\""))
        XCTAssertTrue(result.contains("[model_providers.\(profile.configProviderID)]"))
        XCTAssertTrue(result.contains("name = \"Example Provider\""))
        XCTAssertTrue(result.contains("base_url = \"https://api.example.invalid/v1\""))
        XCTAssertTrue(result.contains("env_key = \"EXAMPLE_PROVIDER_API_KEY\""))
        XCTAssertFalse(result.contains("synthetic-secret-value"))
        XCTAssertTrue(result.contains("goals = true"))
    }

    func testOpenAIRestoresRecordedRootSettingsAfterThirdPartySwitch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try """
        model = "gpt-5.6-terra"
        model_reasoning_effort = "ultra"
        review_model = "gpt-5.5"
        model_provider = "openai"
        [features]
        goals = true
        """.write(to: url, atomically: true, encoding: .utf8)
        let service = CodexConfigService()
        let baseline = service.openAIConfigurationBaseline(from: try service.read(from: url))

        try service.apply(profile: ProviderDefaults.profile(for: .qilin), to: url)
        let thirdParty = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(thirdParty.contains("model = \"gpt-5.5\""))
        XCTAssertTrue(thirdParty.contains("model_reasoning_effort = \"xhigh\""))

        try service.apply(profile: ProviderDefaults.profile(for: .openAI), to: url, openAIBaseline: baseline)
        let restored = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(restored.contains("model = \"gpt-5.6-terra\""))
        XCTAssertTrue(restored.contains("model_reasoning_effort = \"ultra\""))
        XCTAssertTrue(restored.contains("review_model = \"gpt-5.5\""))
        XCTAssertTrue(restored.contains("model_provider = \"openai\""))
        XCTAssertTrue(restored.contains("goals = true"))
    }
    func testChatGPTLoginProfileRendersOpenAIAuthenticationWithoutAnAPIKeyReference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n".write(to: url, atomically: true, encoding: .utf8)
        let profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Login Provider",
            authMode: .chatGPTLogin,
            baseURL: nil,
            wireAPI: "responses",
            model: "gpt-5.5",
            isBuiltIn: false
        )

        try CodexConfigService().apply(profile: profile, to: url)

        let rendered = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(rendered.contains("requires_openai_auth = true"))
        XCTAssertFalse(rendered.contains("env_key ="))
    }

    func testApiKeyProviderDoesNotSilentlyFallBackToAGPTModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n".write(to: url, atomically: true, encoding: .utf8)
        let profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "DeepSeek",
            authMode: .apiKey,
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "DEEPSEEK_API_KEY",
            model: nil,
            isBuiltIn: false
        )

        XCTAssertThrowsError(try CodexConfigService().apply(profile: profile, to: url)) { error in
            XCTAssertEqual(error as? CodexConfigError, .missingModel)
        }
        XCTAssertFalse(try String(contentsOf: url).contains("gpt-5.6-sol"))
    }

    func testManagedModelCatalogWritesPointerForCustomProviderAndRemovesItForOpenAI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n[features]\ngoals = true\n".write(to: url, atomically: true, encoding: .utf8)
        let profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            wireAPI: "responses",
            apiKeyEnvironment: "DEEPSEEK_API_KEY",
            model: "deepseek-v4-pro",
            models: ["deepseek-v4-flash"],
            isBuiltIn: false
        )
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: root)
        let service = CodexConfigService()

        try service.apply(profile: profile, to: url, managesModelCatalog: true)
        let thirdParty = try String(contentsOf: url)
        XCTAssertTrue(thirdParty.contains("model_catalog_json = \"\(catalogURL.path)\""))
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
        let rendered = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        XCTAssertEqual((rendered?["models"] as? [[String: Any]])?.map { $0["slug"] as? String },
                       ["deepseek-v4-pro", "deepseek-v4-flash"])

        try service.apply(profile: ProviderDefaults.profile(for: .openAI), to: url, managesModelCatalog: true)
        let restored = try String(contentsOf: url)
        XCTAssertFalse(restored.contains("model_catalog_json"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertTrue(restored.contains("goals = true"))
    }

    func testGPTOnlyProviderLeavesBundledCatalogAndUserPointerUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        let userPointer = root.appendingPathComponent("user-models.json")
        try "model_provider = \"openai\"\nmodel_catalog_json = \"\(userPointer.path)\"\n[features]\ngoals = true\n"
            .write(to: url, atomically: true, encoding: .utf8)

        try CodexConfigService().apply(
            profile: ProviderDefaults.profile(for: .qilin),
            to: url,
            managesModelCatalog: true,
            modelCatalogSlugs: []
        )

        let rendered = try String(contentsOf: url)
        XCTAssertTrue(rendered.contains("model_catalog_json = \"\(userPointer.path)\""))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ModelCatalogRenderer.managedCatalogURL(codexHome: root).path))
        XCTAssertTrue(rendered.contains("model_provider = \"qilin\""))
    }

    func testExplicitSlugsInstallCatalogForGPTRelay() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n".write(to: url, atomically: true, encoding: .utf8)
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: root)

        try CodexConfigService().apply(
            profile: ProviderDefaults.profile(for: .qilin),
            to: url,
            managesModelCatalog: true,
            modelCatalogSlugs: ["gpt-5.5", "gpt-5.6-sol"]
        )

        let rendered = try String(contentsOf: url)
        XCTAssertTrue(rendered.contains("model_catalog_json = \"\(catalogURL.path)\""))
        let catalog = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let slugs = (catalog?["models"] as? [[String: Any]])?.compactMap { $0["slug"] as? String }
        XCTAssertEqual(slugs, ["gpt-5.5", "gpt-5.6-sol"])
    }

    func testQilinAndVectorEngineAlwaysRenderVersionedBaseURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n".write(to: url, atomically: true, encoding: .utf8)
        var qilin = ProviderDefaults.profile(for: .qilin)
        qilin.baseURL = "https://www.qilinapi.com"
        var vector = ProviderDefaults.profile(for: .vectorEngine)
        vector.baseURL = "https://api.vectorengine.cn"

        try CodexConfigService().apply(profile: qilin, to: url, managesModelCatalog: true, modelCatalogSlugs: [])
        var rendered = try String(contentsOf: url)
        XCTAssertTrue(rendered.contains("base_url = \"https://www.qilinapi.com/v1\""))

        try CodexConfigService().apply(profile: vector, to: url, managesModelCatalog: true, modelCatalogSlugs: [])
        rendered = try String(contentsOf: url)
        XCTAssertTrue(rendered.contains("base_url = \"https://api.vectorengine.cn/v1\""))
    }
}
