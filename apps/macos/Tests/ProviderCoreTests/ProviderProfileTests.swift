import XCTest
@testable import ProviderCore

final class ProviderProfileTests: XCTestCase {
    func testProviderDefaults() {
        XCTAssertTrue(ProviderDefaults.profile(for: .openAI).isBuiltIn)
        XCTAssertEqual(ProviderDefaults.profile(for: .qilin).baseURL, "https://www.qilinapi.com")
        XCTAssertEqual(ProviderDefaults.profile(for: .vectorEngine).baseURL, "https://api.vectorengine.cn/v1")
        XCTAssertEqual(ProviderDefaults.profile(for: .vectorEngine).wireAPI, "responses")
    }

    func testRejectsInvalidThirdPartyProfile() {
        var profile = ProviderDefaults.profile(for: .qilin)
        profile.displayName = " "
        profile.baseURL = "http://example.com"
        profile.wireAPI = ""
        XCTAssertEqual(Set(ProviderValidator.validate(profile).map(\.field)), [.displayName, .baseURL, .wireAPI])
    }

    func testAllowsCustomWireAPI() {
        var profile = ProviderDefaults.profile(for: .vectorEngine)
        profile.wireAPI = "custom-responses"
        XCTAssertTrue(ProviderValidator.validate(profile).isEmpty)
    }
}
