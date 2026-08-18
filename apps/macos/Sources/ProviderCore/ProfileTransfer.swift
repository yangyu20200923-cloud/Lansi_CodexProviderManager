import Foundation

public enum ProfileTransferError: Error, Equatable {
    case builtInProfile
    case invalidProfile
}

/// Converts between the macOS persistence model and the shared Windows-compatible catalog.
public enum ProfileTransfer {
    public static func export(_ profile: ProviderProfile) throws -> Data {
        guard !profile.id.isBuiltIn else { throw ProfileTransferError.builtInProfile }
        guard ProviderValidator.validate(profile).isEmpty else { throw ProfileTransferError.invalidProfile }
        return try encoder.encode(PortableCatalog(profiles: [PortableProfile(profile: profile)]))
    }

    public static func importProfile(from data: Data) throws -> ProviderProfile {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw ProfileTransferError.invalidProfile }
        let profile: ProviderProfile
        if dictionary["profiles"] != nil {
            try validateCatalogShape(dictionary)
            guard let profiles = dictionary["profiles"] as? [[String: Any]], profiles.count == 1 else {
                throw ProfileTransferError.invalidProfile
            }
            try validateCanonicalProfileShape(profiles[0])
            let catalog = try JSONDecoder().decode(PortableCatalog.self, from: data)
            guard let portable = catalog.profiles.first else { throw ProfileTransferError.invalidProfile }
            profile = try portable.providerProfile()
        } else {
            // Previous macOS releases exported one internal profile object. Keep those files importable.
            try validateLegacyProfileShape(dictionary)
            profile = try JSONDecoder().decode(ProviderProfile.self, from: data)
        }
        guard !profile.id.isBuiltIn, !profile.isBuiltIn else { throw ProfileTransferError.builtInProfile }
        guard ProviderValidator.validate(profile).isEmpty else { throw ProfileTransferError.invalidProfile }
        var portable = profile
        portable.hasStoredKey = false
        return portable
    }

    private static let canonicalCatalogKeys: Set<String> = ["profiles"]
    private static let canonicalProfileKeys: Set<String> = [
        "id", "name", "enabled", "authMode", "baseUrl", "wireApi", "apiKeyEnv", "model", "models",
        "reasoningEffort", "reviewModel", "configOverrides"
    ]
    private static let legacyProfileKeys: Set<String> = [
        "id", "displayName", "authMode", "baseURL", "wireAPI", "apiKeyEnvironment", "model", "models",
        "reasoningEffort", "reviewModel", "configOverrides", "isBuiltIn", "enabled", "hasStoredKey"
    ]

    private static func validateCatalogShape(_ catalog: [String: Any]) throws {
        guard Set(catalog.keys) == canonicalCatalogKeys, catalog["profiles"] is [[String: Any]] else {
            throw ProfileTransferError.invalidProfile
        }
    }

    private static func validateCanonicalProfileShape(_ profile: [String: Any]) throws {
        guard Set(profile.keys).isSubset(of: canonicalProfileKeys),
              Set(["id", "name", "enabled", "authMode"]).isSubset(of: Set(profile.keys)) else {
            throw ProfileTransferError.invalidProfile
        }
    }

    private static func validateLegacyProfileShape(_ profile: [String: Any]) throws {
        guard Set(profile.keys).isSubset(of: legacyProfileKeys),
              Set(["id", "displayName", "isBuiltIn"]).isSubset(of: Set(profile.keys)) else {
            throw ProfileTransferError.invalidProfile
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()
}

private struct PortableCatalog: Codable {
    let profiles: [PortableProfile]
}

private struct PortableProfile: Codable {
    let id: String
    let name: String
    let enabled: Bool
    let authMode: ProviderAuthMode
    let baseUrl: String?
    let wireApi: String?
    let apiKeyEnv: String?
    let model: String?
    let models: [String]?
    let reasoningEffort: String?
    let reviewModel: String?
    let configOverrides: [String: String]?

    init(profile: ProviderProfile) {
        id = profile.id.rawValue
        name = profile.displayName
        enabled = profile.enabled
        authMode = profile.authMode
        baseUrl = profile.baseURL
        wireApi = profile.wireAPI
        apiKeyEnv = profile.apiKeyEnvironment
        model = profile.model
        models = profile.models
        reasoningEffort = profile.reasoningEffort
        reviewModel = profile.reviewModel
        configOverrides = profile.configOverrides
    }

    func providerProfile() throws -> ProviderProfile {
        guard UUID(uuidString: id) != nil, let providerID = ProviderID(rawValue: id) else {
            throw ProfileTransferError.invalidProfile
        }
        return ProviderProfile(
            id: providerID,
            displayName: name,
            authMode: authMode,
            baseURL: baseUrl,
            wireAPI: wireApi,
            apiKeyEnvironment: apiKeyEnv,
            model: model,
            models: models ?? [],
            reasoningEffort: reasoningEffort,
            reviewModel: reviewModel,
            configOverrides: configOverrides ?? [:],
            isBuiltIn: false,
            enabled: enabled,
            hasStoredKey: false
        )
    }
}
