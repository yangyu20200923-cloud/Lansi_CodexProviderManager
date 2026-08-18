import XCTest
@testable import ProviderCore

final class ContractFixtureTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    func testQilinRenderingMatchesSharedCompatibilityFixture() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let config = temporary.appendingPathComponent("config.toml")
        let fixtureDirectory = Self.repositoryRoot.appendingPathComponent("spec/config-fixtures")
        let base = try String(contentsOf: fixtureDirectory.appendingPathComponent("base-config.toml"), encoding: .utf8)
        let expected = try String(contentsOf: fixtureDirectory.appendingPathComponent("expected-compatible.toml"), encoding: .utf8)
        try base.write(to: config, atomically: true, encoding: .utf8)

        try CodexConfigService().apply(profile: ProviderDefaults.profile(for: .qilin), to: config)
        let rendered = try String(contentsOf: config)

        XCTAssertEqual(rendered, expected)
    }

    func testLCP03SharedFixtureTransfersAndRendersEveryPortableField() throws {
        let fixtureURL = Self.repositoryRoot.appendingPathComponent("spec/fixtures/lcp-03-provider-parity.json")
        let data = try Data(contentsOf: fixtureURL)
        let profile = try ProfileTransfer.importProfile(from: data)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let config = root.appendingPathComponent("config.toml")
        try "model_provider = \"openai\"\n".write(to: config, atomically: true, encoding: .utf8)

        try CodexConfigService().apply(profile: profile, to: config)
        let exported = try ProfileTransfer.export(profile)
        let rendered = try String(contentsOf: config)
        let exportedCatalog = try JSONSerialization.jsonObject(with: exported) as? [String: Any]
        let exportedProfile = exportedCatalog?["profiles"] as? [[String: Any]]

        XCTAssertEqual(profile.id.rawValue, "35c5a9e6-148b-4ebd-b771-97cf3b04e982")
        XCTAssertEqual(profile.displayName, "LCP-03 Cross-platform Fixture")
        XCTAssertFalse(profile.enabled)
        XCTAssertEqual(profile.authMode, .apiKey)
        XCTAssertEqual(profile.baseURL, "https://api.example.invalid/v1")
        XCTAssertEqual(profile.wireAPI, "responses")
        XCTAssertEqual(profile.apiKeyEnvironment, "LCP03_FIXTURE_API_KEY")
        XCTAssertEqual(profile.model, "lcp-03-model")
        XCTAssertEqual(profile.models, ["lcp-03-model", "lcp-03-fast"])
        XCTAssertEqual(profile.reasoningEffort, "high")
        XCTAssertEqual(profile.reviewModel, "lcp-03-review-model")
        XCTAssertEqual(profile.configOverrides, [:])
        XCTAssertEqual(exportedProfile?.count, 1)
        XCTAssertEqual(exportedProfile?.first?["id"] as? String, profile.id.rawValue)
        XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains("apiKey\""))
        XCTAssertTrue(rendered.contains("model = \"lcp-03-model\""))
        XCTAssertTrue(rendered.contains("model_reasoning_effort = \"high\""))
        XCTAssertTrue(rendered.contains("review_model = \"lcp-03-review-model\""))
        XCTAssertTrue(rendered.contains("env_key = \"LCP03_FIXTURE_API_KEY\""))
    }
}
