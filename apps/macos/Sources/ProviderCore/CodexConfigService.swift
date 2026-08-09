import Foundation

public struct CodexConfig: Equatable, Sendable {
    public var rawText: String
    public var activeProvider: String?

    public init(rawText: String, activeProvider: String? = nil) {
        self.rawText = rawText
        self.activeProvider = activeProvider
    }
}

public enum CodexConfigError: Error, Equatable {
    case unreadable
    case duplicateKey(String)
    case missingProviderBlock(String)
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

    public func apply(profile: ProviderProfile, to url: URL) throws {
        var config = try read(from: url)
        config.rawText = try updated(text: config.rawText, profile: profile)
        config.activeProvider = profile.id.rawValue
        try AtomicFile.replace(url, with: Data(config.rawText.utf8))
    }

    private func updated(text: String, profile: ProviderProfile) throws -> String {
        var lines = text.components(separatedBy: "\n")
        guard !lines.isEmpty else { throw CodexConfigError.malformedProviderBlock }
        func upsertRoot(_ key: String, _ value: String) throws {
            let firstTable = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.count
            let indices = lines.indices.filter {
                guard $0 < firstTable, let equals = lines[$0].firstIndex(of: "=") else { return false }
                return lines[$0][..<equals].trimmingCharacters(in: .whitespaces) == key
            }
            if indices.count > 1 { throw CodexConfigError.duplicateKey(key) }
            if let index = indices.first { lines[index] = "\(key) = \(value)" }
            else { lines.insert("\(key) = \(value)", at: firstTable) }
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
        if !profile.isBuiltIn {
            try upsertRoot("model", "\"gpt-5.6-sol\"")
            try upsertRoot("model_reasoning_effort", "\"xhigh\"")
            try upsertRoot("review_model", "\"\(profile.model ?? "gpt-5.5")\"")
            try upsertTable("history", key: "persistence", value: "\"save-all\"")
            func upsertManagedProvider(_ id: ProviderID) throws {
                let managedProfile = id == profile.id ? profile : ProviderDefaults.profile(for: id)
                let providerHeader = "[model_providers.\(id.rawValue)]"
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
                for index in headerIndex..<blockEnd {
                    let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                    guard let equals = trimmed.firstIndex(of: "=") else { continue }
                    let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                    if ["name", "base_url", "wire_api", "env_key"].contains(key) {
                        if !seen.insert(key).inserted { throw CodexConfigError.duplicateKey(key) }
                        let value: String?
                        switch key {
                        case "name":
                            value = id == .qilin ? "Qilin OpenAI-compatible API" : "VectorEngine OpenAI-compatible API"
                        case "base_url": value = managedProfile.baseURL
                        case "wire_api": value = managedProfile.wireAPI
                        default: value = id == .qilin ? "QILIN_API_KEY" : "VECTORENGINE_API_KEY"
                        }
                        if let value { lines[index] = "\(key) = \(Self.quote(value))" }
                    }
                }
                let required: [(String, String?)] = [
                    ("name", id == .qilin ? "Qilin OpenAI-compatible API" : "VectorEngine OpenAI-compatible API"),
                    ("base_url", managedProfile.baseURL),
                    ("wire_api", managedProfile.wireAPI),
                    ("env_key", id == .qilin ? "QILIN_API_KEY" : "VECTORENGINE_API_KEY")
                ]
                var insertion = blockEnd
                for (key, value) in required where !seen.contains(key) {
                    if let value { lines.insert("\(key) = \(Self.quote(value))", at: insertion); insertion += 1 }
                }
            }
            try upsertManagedProvider(.qilin)
            try upsertManagedProvider(.vectorEngine)
        }

        let modelProvider = "model_provider = \"\(profile.id.rawValue)\""
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
