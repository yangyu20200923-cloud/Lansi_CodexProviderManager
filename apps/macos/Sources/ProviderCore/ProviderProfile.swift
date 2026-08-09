import Foundation

public struct ProviderProfile: Codable, Equatable, Sendable {
    public let id: ProviderID
    public var displayName: String
    public var baseURL: String?
    public var wireAPI: String?
    public var model: String?
    public let isBuiltIn: Bool
    public var hasStoredKey: Bool

    public var canEditConnection: Bool { !isBuiltIn }

    public init(
        id: ProviderID,
        displayName: String,
        baseURL: String?,
        wireAPI: String?,
        model: String?,
        isBuiltIn: Bool,
        hasStoredKey: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.model = model
        self.isBuiltIn = isBuiltIn
        self.hasStoredKey = hasStoredKey
    }
}
