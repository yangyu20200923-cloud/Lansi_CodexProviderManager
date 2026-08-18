import Foundation

public struct CodexConfig: Equatable, Sendable {
    public var rawText: String
    public var activeProvider: String?

    public init(rawText: String, activeProvider: String? = nil) {
        self.rawText = rawText
        self.activeProvider = activeProvider
    }
}

/// The OpenAI root settings that a third-party Provider may temporarily override.
public struct OpenAIConfigurationBaseline: Codable, Equatable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let reviewModel: String?

    public init(model: String?, reasoningEffort: String?, reviewModel: String?) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.reviewModel = reviewModel
    }
}

public enum CodexConfigError: Error, Equatable {
    case unreadable
    case duplicateKey(String)
    case missingProviderBlock(String)
    case missingModel
    case malformedProviderBlock
}

public final class CodexConfigService: @unchecked Sendable {
    public init() {}

    public func read(from url: URL) throws -> CodexConfig {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw CodexConfigError.unreadable }
        return CodexConfig(rawText: text, activeProvider: Self.value(for: "model_provider", in: text))
    }

    public func render(_ config: CodexConfig) -> String { config.rawText }

    public func activeProvider(from text: String) -> String? {
        Self.value(for: "model_provider", in: text)
    }

    public func apply(
        profile: ProviderProfile,
        to url: URL,
        openAIBaseline: OpenAIConfigurationBaseline? = nil,
        managesModelCatalog: Bool = false,
        modelCatalogSlugs: [String]? = nil
    ) throws {
        var config = try read(from: url)
        let codexHome = url.deletingLastPathComponent()
        let catalogURL = ModelCatalogRenderer.managedCatalogURL(codexHome: codexHome)
        let existingPointer = Self.value(for: "model_catalog_json", in: config.rawText)
        let needsCatalog = managesModelCatalog && !profile.isBuiltIn
        var catalogPath: String?
        var updatesCatalogKey = false
        if needsCatalog {
            let slugs = modelCatalogSlugs ?? ModelCatalogRenderer.slugs(profile: profile)
            if slugs.isEmpty {
                // No usable model list: keep Codex's bundled catalog and only remove
                // a pointer the manager itself previously installed.
                if existingPointer == catalogURL.path {
                    updatesCatalogKey = true
                    try? FileManager.default.removeItem(at: catalogURL)
                }
            } else {
                try ModelCatalogRenderer.write(
                    slugs: slugs,
                    primaryModel: profile.model,
                    reasoningEffort: profile.reasoningEffort,
                    codexHome: codexHome
                )
                catalogPath = catalogURL.path
                updatesCatalogKey = true
            }
        } else if managesModelCatalog, existingPointer == catalogURL.path {
            // A previous switch installed the manager-owned pointer. Remove it so the
            // bundled catalog returns, while leaving user-managed pointers untouched.
            updatesCatalogKey = true
            try? FileManager.default.removeItem(at: catalogURL)
        }
        config.rawText = try updated(
            text: config.rawText,
            profile: profile,
            openAIBaseline: openAIBaseline,
            modelCatalogPath: catalogPath,
            updatesCatalogKey: updatesCatalogKey
        )
        config.activeProvider = profile.configProviderID
        try AtomicFile.replace(url, with: Data(config.rawText.utf8))
    }

    public func openAIConfigurationBaseline(from config: CodexConfig) -> OpenAIConfigurationBaseline {
        OpenAIConfigurationBaseline(
            model: Self.value(for: "model", in: config.rawText),
            reasoningEffort: Self.value(for: "model_reasoning_effort", in: config.rawText),
            reviewModel: Self.value(for: "review_model", in: config.rawText)
        )
    }

    private func updated(
        text: String,
        profile: ProviderProfile,
        openAIBaseline: OpenAIConfigurationBaseline?,
        modelCatalogPath: String?,
        updatesCatalogKey: Bool
    ) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { throw CodexConfigError.malformedProviderBlock }
        func upsertRoot(_ key: String, _ value: String?) throws {
            let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            let indices = lines.indices.filter {
                guard $0 < firstTable, let equals = lines[$0].firstIndex(of: "=") else { return false }
                return lines[$0][..<equals].trimmingCharacters(in: .whitespaces) == key
            }
            if indices.count > 1 { throw CodexConfigError.duplicateKey(key) }
            if let value {
                if let index = indices.first { lines[index] = "\(key) = \(value)" }
                else { lines.insert("\(key) = \(value)", at: firstTable) }
            } else if let index = indices.first {
                lines.remove(at: index)
            }
        }
        func upsertTable(_ table: String, key: String, value: String) throws {
            let header = "[\(table)]"
            guard let headerIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == header }) else {
                if lines.last?.isEmpty == false { lines.append("") }
                lines.append(header)
                lines.append("\(key) = \(value)")
                return
            }
            let end = (headerIndex + 1..<lines.count).first { lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            let indices = (headerIndex + 1..<end).filter {
                guard let equals = lines[$0].firstIndex(of: "=") else { return false }
                return lines[$0][..<equals].trimmingCharacters(in: .whitespaces) == key
            }
            if indices.count > 1 { throw CodexConfigError.duplicateKey("\(table).\(key)") }
            if let index = indices.first { lines[index] = "\(key) = \(value)" }
            else { lines.insert("\(key) = \(value)", at: headerIndex + 1) }
        }
        if profile.id == .openAI, let openAIBaseline {
            try upsertRoot("model", openAIBaseline.model.map(Self.quote))
            try upsertRoot("model_reasoning_effort", openAIBaseline.reasoningEffort.map(Self.quote))
            try upsertRoot("review_model", openAIBaseline.reviewModel.map(Self.quote))
        } else if !profile.isBuiltIn {
            // Provider defaults are part of the visible profile contract. In particular, do not
            // silently replace a third-party Provider's declared model with the legacy global one.
            let configuredModel = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if configuredModel.isEmpty && profile.requiresAPIKey {
                throw CodexConfigError.missingModel
            }
            let modelValue = configuredModel.isEmpty ? "gpt-5.6-sol" : configuredModel
            try upsertRoot("model", Self.quote(modelValue))
            try upsertRoot("model_reasoning_effort", profile.reasoningEffort.map { Self.quote($0) })
            try upsertRoot("review_model", profile.reviewModel.map { Self.quote($0) })
            try upsertTable("history", key: "persistence", value: "\"save-all\"")
            func upsertManagedProvider(_ id: ProviderID) throws {
                let managedProfile = id == profile.id ? profile : ProviderDefaults.profile(for: id)
                let providerHeader = "[model_providers.\(managedProfile.configProviderID)]"
                let headerIndex: Int
                if let existing = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == providerHeader }) {
                    headerIndex = existing
                } else {
                    if lines.last?.isEmpty == false { lines.append("") }
                    lines.append(providerHeader)
                    headerIndex = lines.count - 1
                }
                let blockEnd = (headerIndex + 1..<lines.count).first { index in
                    let value = lines[index].trimmingCharacters(in: .whitespaces)
                    return value.hasPrefix("[") && value.hasSuffix("]")
                } ?? lines.count
                var seen = Set<String>()
                var removals: [Int] = []
                for index in headerIndex..<blockEnd {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let equals = trimmed.firstIndex(of: "=") else { continue }
                    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                    if ["name", "base_url", "wire_api", "env_key", "requires_openai_auth"].contains(key) {
                        if !seen.insert(key).inserted { throw CodexConfigError.duplicateKey(key) }
                        let renderedValue: String?
                        switch key {
                        case "name":
                            let name = id == .qilin ? "Qilin OpenAI-compatible API" : id == .vectorEngine ? "VectorEngine OpenAI-compatible API" : managedProfile.displayName
                            renderedValue = Self.quote(name)
                        case "base_url": renderedValue = Self.forcedBaseURL(for: id, profile: managedProfile).map(Self.quote)
                        case "wire_api": renderedValue = managedProfile.wireAPI.map(Self.quote)
                        case "env_key": renderedValue = managedProfile.requiresAPIKey ? managedProfile.apiKeyEnvironment.map(Self.quote) : nil
                        case "requires_openai_auth": renderedValue = managedProfile.authMode == .chatGPTLogin ? "true" : nil
                        default: renderedValue = nil
                        }
                        if let renderedValue { lines[index] = "\(key) = \(renderedValue)" }
                        else { removals.append(index) }
                    }
                }
                for index in removals.reversed() { lines.remove(at: index) }
                let required: [(String, String?)] = [
                    ("name", Self.quote(id == .qilin ? "Qilin OpenAI-compatible API" : id == .vectorEngine ? "VectorEngine OpenAI-compatible API" : managedProfile.displayName)),
                    ("base_url", Self.forcedBaseURL(for: id, profile: managedProfile).map(Self.quote)),
                    ("wire_api", managedProfile.wireAPI.map(Self.quote)),
                    ("env_key", managedProfile.requiresAPIKey ? managedProfile.apiKeyEnvironment.map(Self.quote) : nil),
                    ("requires_openai_auth", managedProfile.authMode == .chatGPTLogin ? "true" : nil)
                ]
                var insertion = blockEnd - removals.count
                for (key, value) in required where !seen.contains(key) {
                    if let value { lines.insert("\(key) = \(value)", at: insertion); insertion += 1 }
                }
            }
            if profile.id == .qilin || profile.id == .vectorEngine {
                try upsertManagedProvider(.qilin)
                try upsertManagedProvider(.vectorEngine)
            } else {
                try upsertManagedProvider(profile.id)
            }
        }

        if updatesCatalogKey {
            try upsertRoot("model_catalog_json", modelCatalogPath.map(Self.quote))
        }

        let modelProvider = "model_provider = \"\(profile.configProviderID)\""
        let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
        let modelProviderIndices = lines.indices.filter {
            guard $0 < firstTable else { return false }
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            guard let equals = trimmed.firstIndex(of: "=") else { return false }
            return trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "model_provider"
        }
        if modelProviderIndices.count > 1 { throw CodexConfigError.duplicateKey("model_provider") }
        if let index = modelProviderIndices.first { lines[index] = modelProvider }
        else { lines.insert(modelProvider, at: 0) }
        if let firstTable = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") }),
           firstTable > 0,
           !lines[firstTable - 1].isEmpty {
            lines.insert("", at: firstTable)
        }
        let rendered = lines.joined(separator: "\n")
        return rendered.hasSuffix("\n") ? rendered : rendered + "\n"
    }

    private static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// Some third-party Providers require their versioned `/v1` base URL; a bare
    /// host makes `/models` and `/responses` resolve to website pages instead of the API.
    private static func forcedBaseURL(for id: ProviderID, profile: ProviderProfile) -> String? {
        switch id {
        case .qilin: return "https://www.qilinapi.com/v1"
        case .vectorEngine: return "https://api.vectorengine.cn/v1"
        default: return profile.baseURL
        }
    }

    private static func value(for key: String, in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == key else { continue }
            let candidate = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            return candidate.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }
}
