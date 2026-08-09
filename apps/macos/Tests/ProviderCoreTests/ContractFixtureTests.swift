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
}
