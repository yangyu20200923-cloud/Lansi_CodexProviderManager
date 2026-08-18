import XCTest
@testable import ProviderCore

final class ProfileTransferTests: XCTestCase {
    func testExportAndImportPreserveOnlyPortableCustomProfileFields() throws {
        let original = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Example Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "EXAMPLE_PROVIDER_API_KEY",
            model: "example-model",
            isBuiltIn: false,
            enabled: false,
            hasStoredKey: true
        )

        let data = try ProfileTransfer.export(original)
        let imported = try ProfileTransfer.importProfile(from: data)

        XCTAssertEqual(imported.id, original.id)
        XCTAssertEqual(imported.displayName, original.displayName)
        XCTAssertEqual(imported.apiKeyEnvironment, "EXAMPLE_PROVIDER_API_KEY")
        XCTAssertFalse(imported.enabled)
        XCTAssertFalse(imported.hasStoredKey)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-secret-value"))
    }

    func testImportRejectsBuiltInProfile() throws {
        let data = try JSONEncoder().encode(ProviderDefaults.profile(for: .qilin))

        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: data))
    }

    func testImportKeepsPreviousMacOSSingleProfileExportCompatible() throws {
        let legacy = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Legacy Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "LEGACY_PROVIDER_API_KEY",
            model: "legacy-model",
            isBuiltIn: false
        )

        let imported = try ProfileTransfer.importProfile(from: JSONEncoder().encode(legacy))

        XCTAssertEqual(imported.id, legacy.id)
        XCTAssertEqual(imported.authMode, .apiKey)
        XCTAssertEqual(imported.displayName, legacy.displayName)
        XCTAssertFalse(imported.hasStoredKey)
    }

    func testPortableTransferRejectsSecretAndUnapprovedOverrides() throws {
        let unsafe = """
        {"profiles":[{
          "id":"35c5a9e6-148b-4ebd-b771-97cf3b04e982",
          "name":"Unsafe","enabled":true,"authMode":"api_key",
          "baseUrl":"https://api.example.invalid/v1","apiKeyEnv":"UNSAFE_API_KEY",
          "apiKey":"synthetic-secret-value"
        }]}
        """
        let override = """
        {"profiles":[{
          "id":"35c5a9e6-148b-4ebd-b771-97cf3b04e982",
          "name":"Unsafe","enabled":true,"authMode":"api_key",
          "baseUrl":"https://api.example.invalid/v1","apiKeyEnv":"UNSAFE_API_KEY",
          "configOverrides":{"model":"unsafe"}
        }]}
        """

        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: Data(unsafe.utf8)))
        XCTAssertThrowsError(try ProfileTransfer.importProfile(from: Data(override.utf8)))
    }
}
