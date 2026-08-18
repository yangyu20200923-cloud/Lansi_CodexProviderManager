import Foundation

public enum IsolatedAcceptanceConfigurationError: Error, Equatable {
    case codexHomeMustBeTemporary
    case profileStoreMustBeTemporary
}

public struct IsolatedAcceptanceConfiguration: Sendable {
    public let codexHome: URL
    public let profileStoreURL: URL

    public init(codexHome: URL, profileStoreURL: URL) throws {
        guard Self.isTemporary(codexHome) else { throw IsolatedAcceptanceConfigurationError.codexHomeMustBeTemporary }
        guard Self.isTemporary(profileStoreURL) else { throw IsolatedAcceptanceConfigurationError.profileStoreMustBeTemporary }
        self.codexHome = codexHome
        self.profileStoreURL = profileStoreURL
    }

    private static func isTemporary(_ url: URL) -> Bool {
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL.path
        let candidate = url.resolvingSymlinksInPath().standardizedFileURL.path
        return candidate == temporaryRoot || candidate.hasPrefix(temporaryRoot + "/")
    }
}
