import Foundation

public enum ModelCatalogError: Error, Equatable, LocalizedError, Sendable {
    case invalidBaseURL
    case missingAPIKey
    case invalidResponse
    case httpStatus(Int)
    case emptyModelList

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Base URL must be a valid HTTPS URL."
        case .missingAPIKey: return "An API key is required to fetch the model list."
        case .invalidResponse: return "The provider returned an unsupported model-list response."
        case .httpStatus(let status): return "The provider model list request failed with HTTP \(status)."
        case .emptyModelList: return "The provider returned no models."
        }
    }
}

/// Fetches an OpenAI-compatible model catalog without changing Codex state.
/// The response is intentionally reduced to model IDs before it reaches the UI.
public struct ModelCatalogService: Sendable {
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetch(baseURL: String, apiKey: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw ModelCatalogError.missingAPIKey }
        guard let url = Self.modelsURL(baseURL: baseURL) else { throw ModelCatalogError.invalidBaseURL }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ModelCatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ModelCatalogError.httpStatus(http.statusCode) }
        let models = try Self.parse(data: data)
        guard !models.isEmpty else { throw ModelCatalogError.emptyModelList }
        return models
    }

    /// Reduces an upstream model list to coding/chat LLMs before it reaches the
    /// Codex picker. Third-party Providers may advertise image/audio/lyrics
    /// models that make the picker unusable without search.
    public static func curatedModels(_ models: [String], alwaysInclude: [String] = []) -> [String] {
        let excluded = [
            "image", "audio", "tts", "speech", "lyric", "embedding", "rerank", "seedream",
            "flux", "sora", "whisper", "suno", "dall", "video", "moderation", "realtime",
            "transcribe", "ocr",
        ]
        let families = [
            "gpt", "claude", "deepseek", "qwen", "o1", "o3", "o4", "o5", "gemini", "llama",
            "mistral", "glm", "kimi", "moonshot", "doubao", "ernie", "spark", "yi-", "minimax",
            "hunyuan", "command-", "phi-", "grok", "codex", "chat",
        ]
        var seen = Set<String>()
        var result: [String] = []
        for model in alwaysInclude {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            result.append(trimmed)
        }
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            let lowered = trimmed.lowercased()
            if excluded.contains(where: { lowered.contains($0) }) { continue }
            if families.contains(where: { lowered.contains($0) }) { result.append(trimmed) }
        }
        if result.isEmpty {
            // Unknown families must still reach the picker; only the messy multi-media
            // entries are filtered when a recognizable LLM family is present.
            for model in models {
                let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { result.append(trimmed) }
            }
        }
        return result
    }

    /// Returns the complete, normalized catalog for the manager picker. Search
    /// is deliberately applied by the UI to this result rather than during
    /// fetch, so no upstream model is silently discarded.
    public static func fullCatalog(_ models: [String], alwaysInclude: [String] = []) -> [String] {
        var seen = Set<String>()
        return (alwaysInclude + models).compactMap { value in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
    }

    public static func matching(_ models: [String], query: String) -> [String] {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return models }
        return models.filter { $0.lowercased().contains(normalized) }
    }

    public static func modelsURL(baseURL: String) -> URL? {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else { return nil }
        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix("models") {
            components.path = "/" + path
        } else {
            components.path = "/" + (path.isEmpty ? "models" : path + "/models")
        }
        return components.url
    }

    public static func parse(data: Data) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: data)
        let rawItems: [[String: Any]]
        if let dictionary = object as? [String: Any], let data = dictionary["data"] as? [[String: Any]] {
            rawItems = data
        } else if let array = object as? [[String: Any]] {
            rawItems = array
        } else {
            throw ModelCatalogError.invalidResponse
        }
        var seen = Set<String>()
        return rawItems.compactMap { item in
            guard let value = item["id"] as? String else { return nil }
            let model = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, seen.insert(model).inserted else { return nil }
            return model
        }
    }
}
