import Foundation
import XCTest
@testable import ProviderCore

final class ModelCatalogRendererTests: XCTestCase {
    func testRenderProducesEveryCodexRequiredField() throws {
        let data = try ModelCatalogRenderer.render(
            slugs: ["deepseek-v4-flash", "deepseek-v4-pro"],
            primaryModel: "deepseek-v4-pro",
            reasoningEffort: "high"
        )
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = try XCTUnwrap(object?["models"] as? [[String: Any]])
        XCTAssertEqual(models.count, 2)

        let primary = try XCTUnwrap(models.first { $0["slug"] as? String == "deepseek-v4-pro" })
        XCTAssertEqual(primary["display_name"] as? String, "Deepseek V4 Pro")
        XCTAssertEqual(primary["default_reasoning_level"] as? String, "high")
        XCTAssertEqual(primary["shell_type"] as? String, "default")
        XCTAssertEqual(primary["visibility"] as? String, "list")
        XCTAssertEqual(primary["supported_in_api"] as? Bool, true)
        XCTAssertNotNil(primary["priority"] as? Int)
        XCTAssertEqual(primary["support_verbosity"] as? Bool, true)
        XCTAssertEqual((primary["truncation_policy"] as? [String: Any])?["mode"] as? String, "tokens")
        XCTAssertEqual(primary["supports_parallel_tool_calls"] as? Bool, true)
        XCTAssertEqual(primary["experimental_supported_tools"] as? [String], [])
        let levels = try XCTUnwrap(primary["supported_reasoning_levels"] as? [[String: Any]])
        let efforts = levels.compactMap { $0["effort"] as? String }
        XCTAssertEqual(efforts, ["low", "medium", "high", "xhigh", "max"])
        XCTAssertTrue(levels.contains { $0["effort"] as? String == "high" })
        XCTAssertTrue(levels.contains { $0["effort"] as? String == "xhigh" })
        XCTAssertTrue(levels.contains { $0["effort"] as? String == "max" })
        XCTAssertFalse(levels.contains { $0["effort"] as? String == "ultra" })
        let messages = try XCTUnwrap(primary["model_messages"] as? [String: Any])
        XCTAssertFalse((messages["instructions_template"] as? String)?.isEmpty ?? true)
        let budget = try XCTUnwrap(messages["token_budget"] as? [String: Any])
        XCTAssertNotNil(budget["reminder_threshold_tokens"] as? Int)
    }

    func testSlugsDeduplicateAndPromotePrimaryModel() {
        let profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com",
            wireAPI: "responses",
            apiKeyEnvironment: "DEEPSEEK_API_KEY",
            model: "deepseek-v4-pro",
            models: ["deepseek-v4-flash", "deepseek-v4-pro"],
            isBuiltIn: false
        )
        XCTAssertEqual(
            ModelCatalogRenderer.slugs(profile: profile),
            ["deepseek-v4-pro", "deepseek-v4-flash"]
        )
    }

    func testRenderRejectsEmptyModelList() {
        XCTAssertThrowsError(try ModelCatalogRenderer.render(slugs: [], primaryModel: nil, reasoningEffort: nil)) { error in
            XCTAssertEqual(error as? ModelCatalogRendererError, .emptyModelList)
        }
    }

    func testWriteCreatesCatalogForCustomProfileAndRemovesItForBuiltInProfile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
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
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: home)

        try ModelCatalogRenderer.write(for: profile, codexHome: home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: catalogURL.path))
        let rendered = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any]
        let models = try XCTUnwrap(rendered?["models"] as? [[String: Any]])
        XCTAssertEqual(models.map { $0["slug"] as? String }, ["deepseek-v4-pro", "deepseek-v4-flash"])

        try ModelCatalogRenderer.write(for: ProviderDefaults.profile(for: .openAI), codexHome: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
    }
}
