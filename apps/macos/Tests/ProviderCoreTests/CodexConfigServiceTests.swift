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
}
