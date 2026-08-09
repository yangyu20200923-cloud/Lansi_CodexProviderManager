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
        XCTAssertFalse(text.localizedCaseInsensitiveContains("api_key"))
        XCTAssertEqual(try store.load(), ProfileSet())
    }
}
