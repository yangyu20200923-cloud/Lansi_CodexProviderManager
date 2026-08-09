import Foundation
import XCTest
@testable import ProviderCore

final class ProfileStoreTests: XCTestCase {
    func testProfileStoreNeverContainsAPIKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: url)
        try store.save(ProfileSet())
        let text = try String(contentsOf: url)
        XCTAssertFalse(text.contains("\"apiKey\""))
        XCTAssertFalse(text.contains("synthetic-secret-value"))
        XCTAssertEqual(try store.load(), ProfileSet())
    }

    func testProfileStorePersistsCustomProviderWithoutItsKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        let store = ProfileStore(fileURL: url)
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
        let expected = ProfileSet(activeProvider: id, profiles: ProviderDefaults.all + [profile])

        try store.save(expected)

        XCTAssertEqual(try store.load(), expected)
        let text = try String(contentsOf: url)
        XCTAssertTrue(text.contains(id.rawValue))
        XCTAssertTrue(text.contains("EXAMPLE_PROVIDER_API_KEY"))
        XCTAssertFalse(text.contains("synthetic-secret-value"))
    }
}
