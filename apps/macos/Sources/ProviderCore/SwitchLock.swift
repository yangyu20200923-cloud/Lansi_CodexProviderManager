import Darwin
import Foundation

public enum SwitchLockError: Error, Equatable {
    case alreadyHeld
    case ownershipLost
}

public final class SwitchLock: @unchecked Sendable {
    public let url: URL
    private let ownerID: String
    private var released = false

    private init(url: URL, ownerID: String) {
        self.url = url
        self.ownerID = ownerID
    }

    deinit {
        try? release()
    }

    public static func acquire(in directory: URL, ownerID: String = UUID().uuidString) throws -> SwitchLock {
        let url = directory.appendingPathComponent(".lansi-codex-provider-switch.lock", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch CocoaError.fileWriteFileExists {
            // A crashed manager can leave the directory behind. Never remove a
            // live lock, but reclaim one whose recorded owner PID is gone so a
            // subsequent switch is not permanently blocked by `alreadyHeld`.
            guard reclaimIfStale(url: url) else {
                throw SwitchLockError.alreadyHeld
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }

        let lock = SwitchLock(url: url, ownerID: ownerID)
        let owner = [
            "ownerID": ownerID,
            "pid": String(ProcessInfo.processInfo.processIdentifier),
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: owner, options: [.sortedKeys])
            try data.write(to: url.appendingPathComponent("owner.json"), options: .atomic)
            return lock
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Returns true only when the existing lock has a valid owner record and
    /// that owner's process is no longer alive. Invalid or unreadable owner
    /// metadata remains held rather than being guessed as stale.
    private static func reclaimIfStale(url: URL) -> Bool {
        let ownerURL = url.appendingPathComponent("owner.json")
        guard let data = try? Data(contentsOf: ownerURL),
              let owner = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let rawPID = owner["pid"],
              let pid = Int32(rawPID),
              pid > 0,
              pid != Int32(ProcessInfo.processInfo.processIdentifier) else {
            return false
        }

        errno = 0
        let result = kill(pid, 0)
        if result == 0 || errno == EPERM {
            return false
        }
        guard errno == ESRCH else { return false }

        // Re-read the owner record immediately before removal. This avoids
        // deleting a lock that another process replaced while we inspected it.
        guard let latest = try? Data(contentsOf: ownerURL), latest == data else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    public func release() throws {
        guard !released else { return }
        let ownerURL = url.appendingPathComponent("owner.json")
        guard let data = try? Data(contentsOf: ownerURL),
              let owner = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              owner["ownerID"] == ownerID else {
            throw SwitchLockError.ownershipLost
        }
        try FileManager.default.removeItem(at: url)
        released = true
    }
}
