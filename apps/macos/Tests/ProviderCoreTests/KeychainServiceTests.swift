import XCTest
@testable import ProviderCore

final class KeychainServiceTests: XCTestCase {
    func testRoundTripUsesIsolatedService() throws {
        let service = KeychainService(service: "com.codex.provider-manager.test.\(UUID().uuidString)")
        defer { try? service.delete(provider: .qilin) }
        try service.write(key: "test-only-value", for: .qilin)
        XCTAssertEqual(try service.read(provider: .qilin), "test-only-value")
    }

    func testOpenAIDoesNotAcceptThirdPartyKey() {
        XCTAssertThrowsError(try KeychainService(service: "test").write(key: "value", for: .openAI))
    }
}
