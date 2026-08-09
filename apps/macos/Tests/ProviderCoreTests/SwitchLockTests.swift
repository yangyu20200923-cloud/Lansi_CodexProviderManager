import Foundation
import XCTest
@testable import ProviderCore

final class SwitchLockTests: XCTestCase {
    func testExclusiveLockRefusesContentionUntilReleased() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let first = try SwitchLock.acquire(in: root, ownerID: "first-owner")
        XCTAssertThrowsError(try SwitchLock.acquire(in: root, ownerID: "second-owner"))

        try first.release()
        let second = try SwitchLock.acquire(in: root, ownerID: "second-owner")
        try second.release()
    }
}
