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

    func testAcquireReclaimsLockOwnedByDeadProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lockURL = root.appendingPathComponent(".lansi-codex-provider-switch.lock", isDirectory: true)
        try FileManager.default.createDirectory(at: lockURL, withIntermediateDirectories: false)
        let owner = """
        {"ownerID":"dead-owner","pid":"99999999","createdAt":"2026-08-17T00:00:00Z"}
        """
        try owner.write(to: lockURL.appendingPathComponent("owner.json"), atomically: true, encoding: .utf8)

        let lock = try SwitchLock.acquire(in: root, ownerID: "new-owner")
        XCTAssertEqual(try String(contentsOf: lock.url.appendingPathComponent("owner.json"), encoding: .utf8).contains("new-owner"), true)
        try lock.release()
    }

    func testAcquireKeepsLockWhenOwnerProcessIsCurrentProcess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let first = try SwitchLock.acquire(in: root, ownerID: "current-owner")
        XCTAssertThrowsError(try SwitchLock.acquire(in: root, ownerID: "second-owner")) { error in
            XCTAssertEqual(error as? SwitchLockError, .alreadyHeld)
        }
        try first.release()
    }

    func testBackupManifestExposesOpaqueBackupID() {
        let manifest = BackupManifest(
            directory: URL(fileURLWithPath: "/synthetic/home/backups/opaque-backup-id"),
            createdAt: Date(),
            files: [],
            isPinned: false
        )

        XCTAssertEqual(manifest.backupID, "opaque-backup-id")
        XCTAssertFalse(manifest.backupID.contains("/"))
    }

    func testCoordinatorRefusesSwitchWhenLockIsHeld() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lock = try SwitchLock.acquire(in: root, ownerID: "other-switch")
        defer { try? lock.release() }

        let result = await ProviderSwitchCoordinator(codexHome: root).apply(target: ProviderDefaults.profile(for: .qilin))

        XCTAssertFalse(result.succeeded)
        XCTAssertEqual(result.phase, .recovering)
    }
}
