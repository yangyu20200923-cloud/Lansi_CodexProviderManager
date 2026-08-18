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

    func testLegacyProfileWithoutEnabledFlagLoadsAsEnabled() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = ProviderID.custom()
        let legacy = """
        {
          "activeProvider": "\(id.rawValue)",
          "profiles": [{
            "id": "\(id.rawValue)",
            "displayName": "Legacy Provider",
            "baseURL": "https://api.example.invalid/v1",
            "wireAPI": "responses",
            "apiKeyEnvironment": "EXAMPLE_PROVIDER_API_KEY",
            "model": "example-model",
            "isBuiltIn": false,
            "hasStoredKey": false
          }]
        }
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ProfileStore(fileURL: url).load()

        XCTAssertTrue(loaded.profiles[0].enabled)
    }

    func testLegacyWireAPIIsMigratedInMemoryWithoutRewritingTheCatalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("profiles.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = ProviderID.custom()
        let legacy = """
        {"activeProvider":"\(id.rawValue)","profiles":[{"id":"\(id.rawValue)","displayName":"Legacy Provider","authMode":"api_key","baseURL":"https://api.example.invalid/v1","wireAPI":"chat_completions","apiKeyEnvironment":"EXAMPLE_PROVIDER_API_KEY","model":"example-model","isBuiltIn":false}]}
        """
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ProfileStore(fileURL: url).load()

        XCTAssertEqual(loaded.profiles[0].wireAPI, "responses")
        XCTAssertTrue((try String(contentsOf: url)).contains("chat_completions"))
    }

    func testProfileStorePersistsDisabledCustomProvider() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProfileStore(fileURL: root.appendingPathComponent("profiles.json"))
        var profile = ProviderProfile(
            id: ProviderID.custom(),
            displayName: "Disabled Provider",
            baseURL: "https://api.example.invalid/v1",
            wireAPI: "responses",
            apiKeyEnvironment: "EXAMPLE_PROVIDER_API_KEY",
            model: "example-model",
            isBuiltIn: false,
            enabled: false
        )
        profile.hasStoredKey = false
        try store.save(ProfileSet(activeProvider: .openAI, profiles: ProviderDefaults.all + [profile]))

        let loaded = try store.load()

        XCTAssertEqual(loaded.profiles.first(where: { $0.id == profile.id })?.enabled, false)
    }
}
