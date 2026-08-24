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

    func testProviderV2RejectsReservedDuplicateAndMixedAuthentication() {
        let first = ProviderProfile(
            id: ProviderID.custom(), providerID: "relay", displayName: "Relay",
            baseURL: "https://api.example.invalid/v1", wireAPI: "responses",
            apiKeyEnvironment: "RELAY_API_KEY", model: "relay-model", isBuiltIn: false
        )
        var second = ProviderProfile(
            id: ProviderID.custom(), providerID: "openai", displayName: "Other",
            authMode: .commandToken, baseURL: "https://api.example.invalid/v1", wireAPI: "responses",
            apiKeyEnvironment: "SHOULD_BE_REMOVED", authCommand: ProviderAuthCommand(command: "relative-command"),
            model: "relay-model", isBuiltIn: false
        )
        XCTAssertNil(second.apiKeyEnvironment)
        var fields = Set(ProviderValidator.validate(second, profiles: [first, second]).map(\.field))
        XCTAssertTrue(fields.contains(.providerID))
        XCTAssertTrue(fields.contains(.authentication))

        second.changeProviderID(to: "relay")
        fields = Set(ProviderValidator.validate(second, profiles: [first, second]).map(\.field))
        XCTAssertTrue(fields.contains(.providerID))
        XCTAssertFalse(second.legacyAliases.contains("openai"))
        second.preserveLegacyAlias("openai")
        XCTAssertTrue(second.legacyAliases.contains("openai"))
    }
}
