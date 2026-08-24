import Foundation

/// Persists only the OpenAI root settings that this app temporarily changes for a third-party Provider.
public final class OpenAIConfigurationBaselineStore: @unchecked Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            self.fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexProviderManager/openai-configuration-baseline.json")
        }
    }

    public func load() throws -> OpenAIConfigurationBaseline? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(OpenAIConfigurationBaseline.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ baseline: OpenAIConfigurationBaseline) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try AtomicFile.replace(fileURL, with: JSONEncoder().encode(baseline))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
