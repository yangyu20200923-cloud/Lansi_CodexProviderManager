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
            throw SwitchLockError.alreadyHeld
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
