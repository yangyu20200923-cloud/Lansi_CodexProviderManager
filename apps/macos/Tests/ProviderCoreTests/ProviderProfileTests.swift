import XCTest
@testable import ProviderCore

final class ProviderProfileTests: XCTestCase {
    func testProviderDefaults() {
        XCTAssertTrue(ProviderDefaults.profile(for: .openAI).isBuiltIn)
        XCTAssertEqual(ProviderID.defaultPresetIDs, [.openAI])
        XCTAssertEqual(ProviderDefaults.all.map(\.id), [.openAI])
    }

    func testRejectsInvalidThirdPartyProfile() {
        var profile = ProviderDefaults.profile(for: .qilin)
        profile.displayName = " "
        profile.baseURL = "http://example.com"
        profile.wireAPI = ""
        XCTAssertEqual(Set(ProviderValidator.validate(profile).map(\.field)), [.displayName, .baseURL, .wireAPI])
    }

    func testRejectsUnsupportedWireAPI() {
        var profile = ProviderDefaults.profile(for: .vectorEngine)
        profile.wireAPI = "custom-responses"
        XCTAssertEqual(ProviderValidator.validate(profile).map(\.field), [.wireAPI])
    }

    func testCustomProviderHasStableUUIDAndDedicatedConfigKey() {
        let id = ProviderID.custom()
        let profile = ProviderProfile(
            id: id,
            displayName: "Example Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "EXAMPLE_PROVIDER_API_KEY",
            model: "example-model",
            isBuiltIn: false
        )

        XCTAssertTrue(UUID(uuidString: id.rawValue) != nil)
        XCTAssertTrue(profile.configProviderID.hasPrefix("custom_"))
        XCTAssertFalse(profile.configProviderID.contains("-"))
        XCTAssertTrue(ProviderValidator.validate(profile).isEmpty)
    }

    func testDuplicateCreatesNewEnabledProfileWithoutStoredKeyState() {
        let original = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Example Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "EXAMPLE_PROVIDER_API_KEY",
            model: "example-model",
            isBuiltIn: false,
            hasStoredKey: true
        )

        let duplicate = original.duplicated()

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.baseURL, original.baseURL)
        XCTAssertEqual(duplicate.wireAPI, original.wireAPI)
        XCTAssertEqual(duplicate.apiKeyEnvironment, original.apiKeyEnvironment)
        XCTAssertTrue(duplicate.enabled)
        XCTAssertFalse(duplicate.hasStoredKey)
    }
}
