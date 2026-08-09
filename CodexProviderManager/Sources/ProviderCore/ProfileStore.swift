import Foundation

public struct ProfileSet: Codable, Equatable, Sendable {
    public var activeProvider: ProviderID
    public var profiles: [ProviderProfile]

    public init(activeProvider: ProviderID = .openAI, profiles: [ProviderProfile] = ProviderDefaults.all) {
        self.activeProvider = activeProvider
        self.profiles = profiles
    }
}

public final class ProfileStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexProviderManager/profiles.json")
        }
    }

    public func load() throws -> ProfileSet {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ProfileSet() }
        return try JSONDecoder().decode(ProfileSet.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ profileSet: ProfileSet) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.pretty.encode(profileSet)
        let temporaryURL = directory.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
        } else {
            try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
