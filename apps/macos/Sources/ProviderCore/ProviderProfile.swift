import Foundation

public enum ProviderAuthMode: String, Codable, Equatable, Sendable, CaseIterable {
    case openAILogin = "openai_login"
    case environmentKey = "environment_key"
    case commandToken = "command_token"

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        switch try container.decode(String.self) {
        case "chatgpt_login", Self.openAILogin.rawValue: self = .openAILogin
        case "api_key", Self.environmentKey.rawValue: self = .environmentKey
        case Self.commandToken.rawValue: self = .commandToken
        default:
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported Provider authentication mode.")
        }
    }
}

public struct ProviderAuthCommand: Codable, Equatable, Sendable {
    public var command: String
    public var timeoutMilliseconds: Int
    public var refreshIntervalMilliseconds: Int?
    public var workingDirectory: String?

    public init(
        command: String = "",
        timeoutMilliseconds: Int = 10_000,
        refreshIntervalMilliseconds: Int? = nil,
        workingDirectory: String? = nil
    ) {
        self.command = command
        self.timeoutMilliseconds = timeoutMilliseconds
        self.refreshIntervalMilliseconds = refreshIntervalMilliseconds
        self.workingDirectory = workingDirectory
    }
}

public struct ProviderProfile: Codable, Equatable, Sendable {
    public static let reservedProviderIDs = Set(["openai", "ollama", "lmstudio"])

    public let id: ProviderID
    public var providerID: String
    public var displayName: String
    public var authMode: ProviderAuthMode
    public var baseURL: String?
    public var wireAPI: String?
    public var apiKeyEnvironment: String?
    public var authCommand: ProviderAuthCommand?
    public var httpHeaders: [String: String]
    public var environmentHTTPHeaders: [String: String]
    public var model: String?
    public var models: [String]
    public var reasoningEffort: String?
    public var reviewModel: String?
    public var supportsStandaloneWebSearch: Bool
    public var legacyAliases: [String]
    public var configOverrides: [String: String]
    public let isBuiltIn: Bool
    public var enabled: Bool
    public var hasStoredKey: Bool

    public var canEditConnection: Bool { !isBuiltIn }
    public var requiresAPIKey: Bool { authMode == .environmentKey }
    public var configProviderID: String { isBuiltIn ? id.rawValue : providerID }

    public init(
        id: ProviderID,
        providerID: String? = nil,
        displayName: String,
        authMode: ProviderAuthMode? = nil,
        baseURL: String?,
        wireAPI: String?,
        apiKeyEnvironment: String? = nil,
        authCommand: ProviderAuthCommand? = nil,
        httpHeaders: [String: String] = [:],
        environmentHTTPHeaders: [String: String] = [:],
        model: String?,
        models: [String] = [],
        reasoningEffort: String? = nil,
        reviewModel: String? = nil,
        supportsStandaloneWebSearch: Bool = false,
        legacyAliases: [String] = [],
        configOverrides: [String: String] = [:],
        isBuiltIn: Bool,
        enabled: Bool = true,
        hasStoredKey: Bool = false
    ) {
        let legacyID = Self.legacyConfigProviderID(for: id)
        self.id = id
        self.providerID = isBuiltIn ? id.rawValue : (providerID ?? legacyID)
        self.displayName = displayName
        self.authMode = authMode ?? (id == .openAI ? .openAILogin : .environmentKey)
        self.baseURL = baseURL
        self.wireAPI = isBuiltIn ? wireAPI : "responses"
        self.apiKeyEnvironment = apiKeyEnvironment
        self.authCommand = authCommand
        self.httpHeaders = httpHeaders
        self.environmentHTTPHeaders = environmentHTTPHeaders
        self.model = model
        self.models = Self.normalizedStrings(models)
        self.reasoningEffort = reasoningEffort
        self.reviewModel = reviewModel
        self.supportsStandaloneWebSearch = supportsStandaloneWebSearch
        self.legacyAliases = Self.normalizedStrings(legacyAliases)
        self.configOverrides = configOverrides
        self.isBuiltIn = isBuiltIn
        self.enabled = enabled
        self.hasStoredKey = hasStoredKey
        normalizeAuthentication()
    }

    public func duplicated(existingProviderIDs: Set<String> = []) -> ProviderProfile {
        let base = providerID + "_copy"
        var candidate = base
        var suffix = 2
        while existingProviderIDs.contains(candidate.lowercased()) || Self.reservedProviderIDs.contains(candidate.lowercased()) {
            candidate = "\(base)_\(suffix)"
            suffix += 1
        }
        return ProviderProfile(
            id: ProviderID.custom(),
            providerID: candidate,
            displayName: displayName + " Copy",
            authMode: authMode,
            baseURL: baseURL,
            wireAPI: wireAPI,
            apiKeyEnvironment: apiKeyEnvironment,
            authCommand: authCommand,
            httpHeaders: httpHeaders,
            environmentHTTPHeaders: environmentHTTPHeaders,
            model: model,
            models: models,
            reasoningEffort: reasoningEffort,
            reviewModel: reviewModel,
            supportsStandaloneWebSearch: supportsStandaloneWebSearch,
            configOverrides: configOverrides,
            isBuiltIn: false
        )
    }

    public mutating func normalize() {
        providerID = providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        wireAPI = isBuiltIn ? wireAPI : "responses"
        models = Self.normalizedStrings(models)
        legacyAliases = Self.normalizedStrings(legacyAliases).filter { $0 != providerID }
        normalizeAuthentication()
    }

    public mutating func changeProviderID(to value: String) {
        providerID = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        legacyAliases = Self.normalizedStrings(legacyAliases).filter { $0 != providerID }
    }

    public mutating func preserveLegacyAlias(_ value: String) {
        let alias = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !alias.isEmpty, alias != providerID, !legacyAliases.contains(alias) else { return }
        legacyAliases.append(alias)
    }

    private mutating func normalizeAuthentication() {
        switch authMode {
        case .openAILogin:
            apiKeyEnvironment = nil
            authCommand = nil
        case .environmentKey:
            authCommand = nil
        case .commandToken:
            apiKeyEnvironment = nil
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, providerID, displayName, authMode, baseURL, wireAPI, apiKeyEnvironment, authCommand
        case httpHeaders, environmentHTTPHeaders, model, models, reasoningEffort, reviewModel
        case supportsStandaloneWebSearch, legacyAliases, configOverrides, isBuiltIn, enabled, hasStoredKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ProviderID.self, forKey: .id)
        isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
        let legacyID = Self.legacyConfigProviderID(for: id)
        let decodedProviderID = try container.decodeIfPresent(String.self, forKey: .providerID)
            ?? (isBuiltIn ? id.rawValue : legacyID)
        providerID = decodedProviderID
        displayName = try container.decode(String.self, forKey: .displayName)
        authMode = try container.decodeIfPresent(ProviderAuthMode.self, forKey: .authMode)
            ?? (id == .openAI ? .openAILogin : .environmentKey)
        baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL)
        wireAPI = isBuiltIn ? try container.decodeIfPresent(String.self, forKey: .wireAPI) : "responses"
        apiKeyEnvironment = try container.decodeIfPresent(String.self, forKey: .apiKeyEnvironment)
        authCommand = try container.decodeIfPresent(ProviderAuthCommand.self, forKey: .authCommand)
        httpHeaders = try container.decodeIfPresent([String: String].self, forKey: .httpHeaders) ?? [:]
        environmentHTTPHeaders = try container.decodeIfPresent([String: String].self, forKey: .environmentHTTPHeaders) ?? [:]
        model = try container.decodeIfPresent(String.self, forKey: .model)
        models = Self.normalizedStrings(try container.decodeIfPresent([String].self, forKey: .models) ?? [])
        reasoningEffort = try container.decodeIfPresent(String.self, forKey: .reasoningEffort)
        reviewModel = try container.decodeIfPresent(String.self, forKey: .reviewModel)
        supportsStandaloneWebSearch = try container.decodeIfPresent(Bool.self, forKey: .supportsStandaloneWebSearch) ?? false
        legacyAliases = Self.normalizedStrings(
            try container.decodeIfPresent([String].self, forKey: .legacyAliases)
                ?? (isBuiltIn ? [] : [legacyID])
        ).filter { $0 != decodedProviderID }
        configOverrides = try container.decodeIfPresent([String: String].self, forKey: .configOverrides) ?? [:]
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        hasStoredKey = try container.decodeIfPresent(Bool.self, forKey: .hasStoredKey) ?? false
        normalizeAuthentication()
    }

    private static func legacyConfigProviderID(for id: ProviderID) -> String {
        id.isBuiltIn ? id.rawValue : "custom_" + id.rawValue.replacingOccurrences(of: "-", with: "")
    }

    private static func normalizedStrings(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }
}
