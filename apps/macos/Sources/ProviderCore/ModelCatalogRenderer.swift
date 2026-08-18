import Foundation

public enum ModelCatalogRendererError: Error, Equatable, Sendable {
    case emptyModelList
}

/// Renders the manager-owned model catalog that Codex reads through the top-level
/// `model_catalog_json` setting. Codex replaces the entire bundled catalog with this
/// file, so every entry must contain the fields the desktop runtime requires;
/// a missing required field makes Codex reject the catalog at startup.
public struct ModelCatalogRenderer: Sendable {
    public struct ReasoningLevel: Codable, Equatable, Sendable {
        public let effort: String
        public let description: String

        public init(effort: String, description: String) {
            self.effort = effort
            self.description = description
        }
    }

    public struct TokenBudget: Codable, Equatable, Sendable {
        public let reminderThresholdTokens: Int
        public let reminderMessageTemplate: String
        public let guidanceMessage: String
        public let autoCompactFallbackPrompt: String
        public let autoCompactFallbackBufferTokens: Int
    }

    public struct ModelMessages: Codable, Equatable, Sendable {
        public let instructionsTemplate: String
        public let instructionsVariables: String?
        public let approvals: String?
        public let collaborationModes: String?
        public let autoReview: String?
        public let permissions: String?
        public let tokenBudget: TokenBudget
    }

    public struct TruncationPolicy: Codable, Equatable, Sendable {
        public let mode: String
        public let limit: Int
    }

    public struct Entry: Codable, Equatable, Sendable {
        public let slug: String
        public let displayName: String
        public let description: String?
        public let defaultReasoningLevel: String?
        public let supportedReasoningLevels: [ReasoningLevel]
        public let shellType: String
        public let visibility: String
        public let supportedInAPI: Bool
        public let priority: Int
        public let supportVerbosity: Bool
        public let truncationPolicy: TruncationPolicy
        public let supportsParallelToolCalls: Bool
        public let experimentalSupportedTools: [String]
        public let modelMessages: ModelMessages
    }

    public struct Document: Codable, Equatable, Sendable {
        public let models: [Entry]
    }

    private static let knownEfforts = ["low", "medium", "high", "xhigh", "max", "ultra"]
    private static let effortDescriptions: [String: String] = [
        "low": "Fast responses with lighter reasoning",
        "medium": "Balances speed and reasoning depth",
        "high": "Greater reasoning depth",
        "xhigh": "Extra high reasoning depth",
        "max": "Maximum reasoning depth",
        "ultra": "Maximum reasoning with automatic delegation"
    ]

    /// The manager-owned catalog location. It lives outside the backup sets on purpose:
    /// config.toml keeps the pointer and this file is regenerated on every switch and restore.
    public static func managedCatalogURL(codexHome: URL) -> URL {
        codexHome.appendingPathComponent("CodexProviderManager", isDirectory: true)
            .appendingPathComponent("model-catalog.json", isDirectory: false)
    }

    /// Deduplicates a profile's model list and always includes the configured primary model first.
    public static func slugs(profile: ProviderProfile) -> [String] {
        let primary = profile.model
        return slugs(from: profile.models, primary: primary)
    }

    /// Deduplicates candidate slugs while promoting the primary model to the front.
    public static func slugs(from candidates: [String], primary: String?) -> [String] {
        let primary = primary?.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var result: [String] = []
        for candidate in ([primary].compactMap { $0 } + candidates) where !candidate.isEmpty {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        return result
    }

    public static func render(slugs: [String], primaryModel: String?, reasoningEffort: String?) throws -> Data {
        let entries = try Self.entries(slugs: slugs, primaryModel: primaryModel, reasoningEffort: reasoningEffort)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return try encoder.encode(Document(models: entries))
    }

    public static func write(for profile: ProviderProfile, codexHome: URL) throws {
        guard !profile.isBuiltIn else {
            try? FileManager.default.removeItem(at: managedCatalogURL(codexHome: codexHome))
            return
        }
        let slugs = Self.slugs(profile: profile)
        guard !slugs.isEmpty else {
            try? FileManager.default.removeItem(at: managedCatalogURL(codexHome: codexHome))
            return
        }
        try write(slugs: slugs, primaryModel: profile.model, reasoningEffort: profile.reasoningEffort, codexHome: codexHome)
    }

    /// Writes an explicit, already-resolved slug list. Empty lists remove the managed catalog.
    public static func write(
        slugs: [String],
        primaryModel: String?,
        reasoningEffort: String?,
        codexHome: URL
    ) throws {
        guard !slugs.isEmpty else {
            try? FileManager.default.removeItem(at: managedCatalogURL(codexHome: codexHome))
            return
        }
        let directory = managedCatalogURL(codexHome: codexHome).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try render(slugs: slugs, primaryModel: primaryModel, reasoningEffort: reasoningEffort)
        try AtomicFile.replace(managedCatalogURL(codexHome: codexHome), with: data)
    }

    /// Keeps the catalog file consistent with a restored provider. OpenAI removes the
    /// manager file; every other provider regenerates it from the restored profile.
    public static func synchronize(for profile: ProviderProfile, codexHome: URL) throws {
        try write(for: profile, codexHome: codexHome)
    }

    static func entries(slugs: [String], primaryModel: String?, reasoningEffort: String?) throws -> [Entry] {
        let normalized = slugs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw ModelCatalogRendererError.emptyModelList }
        let primary = primaryModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primaryEffort = normalizedEffort(reasoningEffort)
        return normalized.enumerated().map { index, slug in
            let isPrimary = primary != nil && slug == primary
            let defaultLevel = isPrimary ? primaryEffort : "low"
            // Non-GPT OpenAI-compatible providers accept low/medium/high/xhigh/max.
            // `medium` and `xhigh` map to `high`, `max` maps to `max`; `ultra` is Codex/OpenAI-specific
            // and is intentionally omitted for third-party providers.
            var levels = ["low", "medium", "high", "xhigh", "max"]
            if !levels.contains(defaultLevel) { levels.append(defaultLevel) }
            return Entry(
                slug: slug,
                displayName: displayName(for: slug),
                description: "Model \(slug) served by this provider.",
                defaultReasoningLevel: defaultLevel,
                supportedReasoningLevels: levels.map { ReasoningLevel(effort: $0, description: effortDescriptions[$0] ?? "Reasoning level \($0)") },
                shellType: "default",
                visibility: "list",
                supportedInAPI: true,
                priority: index + 1,
                supportVerbosity: true,
                truncationPolicy: TruncationPolicy(mode: "tokens", limit: 10000),
                supportsParallelToolCalls: true,
                experimentalSupportedTools: [],
                modelMessages: ModelMessages(
                    instructionsTemplate: "You are Codex, an AI coding assistant.",
                    instructionsVariables: nil,
                    approvals: nil,
                    collaborationModes: nil,
                    autoReview: nil,
                    permissions: nil,
                    tokenBudget: TokenBudget(
                        reminderThresholdTokens: 6144,
                        reminderMessageTemplate: "The context window is nearly exhausted.",
                        guidanceMessage: "",
                        autoCompactFallbackPrompt: "",
                        autoCompactFallbackBufferTokens: 16384
                    )
                )
            )
        }
    }

    private static func normalizedEffort(_ value: String?) -> String {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              knownEfforts.contains(value) else { return "low" }
        return value
    }

    private static func displayName(for slug: String) -> String {
        let parts = slug.split(separator: "-").map { component in
            guard let first = component.first else { return "" }
            return String(first).uppercased() + component.dropFirst()
        }
        let joined = parts.joined(separator: " ")
        return joined.isEmpty ? slug : joined
    }
}
