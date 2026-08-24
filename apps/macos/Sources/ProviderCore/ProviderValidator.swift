import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Field: String, Sendable {
        case providerID
        case displayName
        case authentication
        case baseURL
        case wireAPI
        case apiKeyEnvironment
        case model
        case reasoningEffort
        case reviewModel
        case headers
        case configOverrides
    }

    public let field: Field
    public let message: String

    public init(field: Field, message: String) {
        self.field = field
        self.message = message
    }
}

public enum ProviderValidator {
    public static func validate(_ profile: ProviderProfile, profiles: [ProviderProfile] = []) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
        let providerID = profile.providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if providerID.range(of: "^[a-z][a-z0-9_-]{0,63}$", options: .regularExpression) == nil {
            issues.append(.init(field: .providerID, message: "Provider ID must start with a lowercase letter and contain only lowercase letters, digits, underscores, or hyphens."))
        } else if !profile.isBuiltIn, ProviderProfile.reservedProviderIDs.contains(providerID) {
            issues.append(.init(field: .providerID, message: "openai, ollama, and lmstudio are reserved Provider IDs."))
        } else if profiles.contains(where: { $0.id != profile.id && $0.providerID.caseInsensitiveCompare(providerID) == .orderedSame }) {
            issues.append(.init(field: .providerID, message: "Provider ID is already used by another profile."))
        }

        if profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(field: .displayName, message: "Display name is required."))
        }
        if !profile.configOverrides.isEmpty {
            issues.append(.init(field: .configOverrides, message: "No configuration overrides are approved."))
        }
        for (value, field, description) in [
            (profile.model, ValidationIssue.Field.model, "Model"),
            (profile.reasoningEffort, ValidationIssue.Field.reasoningEffort, "Reasoning effort"),
            (profile.reviewModel, ValidationIssue.Field.reviewModel, "Review model")
        ] where value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
            issues.append(.init(field: field, message: "\(description) cannot be empty."))
        }

        var seenModels = Set<String>()
        for model in profile.models {
            let normalized = model.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty || !seenModels.insert(normalized).inserted {
                issues.append(.init(field: .model, message: "Model list contains an empty or duplicate model."))
                break
            }
        }

        let wireAPI = profile.wireAPI?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !profile.isBuiltIn, wireAPI != "responses" {
            issues.append(.init(field: .wireAPI, message: "Only the Responses API is supported by the current Codex version."))
        }

        if !profile.isBuiltIn {
            let selectedModel = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if selectedModel.isEmpty {
                issues.append(.init(field: .model, message: "A model is required. Select one or add a custom model."))
            } else if !profile.models.isEmpty && !profile.models.contains(selectedModel) {
                issues.append(.init(field: .model, message: "The selected model is not in this Provider's model list."))
            }

            let rawURL = profile.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let components = URLComponents(string: rawURL),
               components.scheme?.lowercased() == "https",
               components.host?.isEmpty == false {
                // Valid provider endpoint.
            } else {
                issues.append(.init(field: .baseURL, message: "Base URL must be a valid HTTPS URL."))
            }
        }

        switch profile.authMode {
        case .openAILogin:
            if profile.apiKeyEnvironment?.isEmpty == false || profile.authCommand != nil {
                issues.append(.init(field: .authentication, message: "OpenAI login cannot be combined with an environment key or token command."))
            }
        case .environmentKey:
            let environment = profile.apiKeyEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if environment.range(of: "^[A-Z][A-Z0-9_]{0,127}$", options: .regularExpression) == nil {
                issues.append(.init(field: .apiKeyEnvironment, message: "API key environment variable is required."))
            }
            if profile.authCommand != nil {
                issues.append(.init(field: .authentication, message: "Environment-key authentication cannot be combined with a token command."))
            }
        case .commandToken:
            let command = profile.authCommand?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !command.hasPrefix("/") {
                issues.append(.init(field: .authentication, message: "Token command must use an absolute executable path."))
            }
            if let timeout = profile.authCommand?.timeoutMilliseconds, !(100...300_000).contains(timeout) {
                issues.append(.init(field: .authentication, message: "Token command timeout must be between 100 and 300000 milliseconds."))
            }
            if profile.apiKeyEnvironment?.isEmpty == false {
                issues.append(.init(field: .authentication, message: "Token-command authentication cannot be combined with an API key environment variable."))
            }
        }

        let sensitiveHeaders = Set(["authorization", "proxy-authorization", "x-api-key", "api-key"])
        if profile.httpHeaders.contains(where: { key, value in
            key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.isEmpty || sensitiveHeaders.contains(key.lowercased())
        }) {
            issues.append(.init(field: .headers, message: "Fixed headers must be non-empty and cannot contain credentials; use an environment header mapping for secrets."))
        }
        if profile.environmentHTTPHeaders.contains(where: { key, value in
            key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                value.range(of: "^[A-Z][A-Z0-9_]{0,127}$", options: .regularExpression) == nil
        }) {
            issues.append(.init(field: .headers, message: "Environment headers must map a non-empty header name to a valid environment variable."))
        }
        return issues
    }
}
