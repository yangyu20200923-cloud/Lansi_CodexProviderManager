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
        XCTAssertTrue(result.contains("model = \"gpt-5.6-sol\""))
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
}
