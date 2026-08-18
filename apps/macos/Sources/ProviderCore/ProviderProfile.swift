import Foundation

public enum ProviderAuthMode: String, Codable, Equatable, Sendable {
    case chatGPTLogin = "chatgpt_login"
    case apiKey = "api_key"
}

public struct ProviderProfile: Codable, Equatable, Sendable {
    public let id: ProviderID
    public var displayName: String
    public var authMode: ProviderAuthMode
    public var baseURL: String?
    public var wireAPI: String?
    public var apiKeyEnvironment: String?
    public var model: String?
    /// Optional provider-specific model catalog. The selected `model` remains the
    /// value rendered to Codex; this list is only used by the manager UI and may
    /// be populated manually or from the provider's `/models` endpoint.
    public var models: [String]
    public var reasoningEffort: String?
    public var reviewModel: String?
    /// The public schema currently approves no override keys, so valid profiles keep this empty.
    public var configOverrides: [String: String]
    public let isBuiltIn: Bool
    public var enabled: Bool
    public var hasStoredKey: Bool

    public var canEditConnection: Bool { !isBuiltIn }
    public var requiresAPIKey: Bool { authMode == .apiKey }
    public var configProviderID: String {
        id.isBuiltIn ? id.rawValue : "custom_" + id.rawValue.replacingOccurrences(of: "-", with: "")
    }

    public init(
        id: ProviderID,
        displayName: String,
        authMode: ProviderAuthMode? = nil,
        baseURL: String?,
        wireAPI: String?,
        apiKeyEnvironment: String? = nil,
        model: String?,
        models: [String] = [],
        reasoningEffort: String? = nil,
        reviewModel: String? = nil,
        configOverrides: [String: String] = [:],
        isBuiltIn: Bool,
        enabled: Bool = true,
        hasStoredKey: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.authMode = authMode ?? (id == .openAI ? .chatGPTLogin : .apiKey)
        self.baseURL = baseURL
        self.wireAPI = wireAPI
        self.apiKeyEnvironment = apiKeyEnvironment
        self.model = model
        self.models = Self.normalizedModels(models)
        self.reasoningEffort = reasoningEffort
        self.reviewModel = reviewModel
        self.configOverrides = configOverrides
        self.isBuiltIn = isBuiltIn
        self.enabled = enabled
        self.hasStoredKey = hasStoredKey
    }

    public func duplicated() -> ProviderProfile {
        ProviderProfile(
            id: ProviderID.custom(),
            displayName: displayName + " Copy",
            authMode: authMode,
            baseURL: baseURL,
            wireAPI: wireAPI,
            apiKeyEnvironment: apiKeyEnvironment,
            model: model,
            models: models,
            reasoningEffort: reasoningEffort,
            reviewModel: reviewModel,
            configOverrides: configOverrides,
            isBuiltIn: false,
            enabled: true,
            hasStoredKey: false
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, authMode, baseURL, wireAPI, apiKeyEnvironment, model, models, reasoningEffort, reviewModel, configOverrides, isBuiltIn, enabled, hasStoredKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        authMode = try container.decodeIfPresent(ProviderAuthMode.self, forKey: .authMode)
            ?? (id == .openAI ? .chatGPTLogin : .apiKey)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        wireAPI = try container.decodeIfPresent(String.self, forKey: .wireAPI)
        apiKeyEnvironment = try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        models = Self.normalizedModels(try container.decodeIfPresent([String].self, forKey: .models) ?? [])
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel)
        configOverrides = try container.decodeIfPresent([String: String].self, forKey: .configOverrides) ?? [:]
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hasStoredKey = try container.decodeIfPresent(Bool.self, forKey: .hasStoredKey) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(authMode, forKey: .authMode)
        try container.encodeIfPresent(baseURL, forKey: .baseURL)
        try container.encodeIfPresent(wireAPI, forKey: .wireAPI)
        try container.encodeIfPresent(apiKeyEnvironment, forKey: .apiKeyEnvironment)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(models, forKey: .models)
        try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)
        try container.encodeIfPresent(reviewModel, forKey: .reviewModel)
        try container.encode(configOverrides, forKey: .configOverrides)
        try container.encode(isBuiltIn, forKey: .isBuiltIn)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(hasStoredKey, forKey: .hasStoredKey)
    }

    private static func normalizedModels(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
