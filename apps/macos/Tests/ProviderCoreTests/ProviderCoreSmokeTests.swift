import XCTest
@testable import ProviderCore

final class ProviderCoreSmokeTests: XCTestCase {
    func testOpenAIProviderIDRawValue() {
        XCTAssertEqual(ProviderID.openAI.rawValue, "openai")
    }

    func testAllProvidersAreAvailable() {
        XCTAssertEqual(Set(ProviderID.builtInIDs), [.openAI, .qilin, .vectorEngine])
    }
}
