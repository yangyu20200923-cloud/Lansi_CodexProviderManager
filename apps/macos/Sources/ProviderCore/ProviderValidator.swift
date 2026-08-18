import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Field: String, Sendable {
        case displayName
        case baseURL
        case wireAPI
        case apiKeyEnvironment
        case model
        case reasoningEffort
        case reviewModel
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
    public static func validate(_ profile: ProviderProfile) -> [ValidationIssue] {
        var issues: [ValidationIssue] = []
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
        if !profile.isBuiltIn, !wireAPI.isEmpty, wireAPI != "responses" {
            issues.append(.init(field: .wireAPI, message: "Only the Responses API is supported by the current Codex version."))
        }

        guard profile.requiresAPIKey else { return issues }

        let selectedModel = profile.model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if selectedModel.isEmpty {
            issues.append(.init(field: .model, message: "A model is required for API-key Providers. Select one or add a custom model."))
        } else if !profile.models.isEmpty && !profile.models.contains(selectedModel) {
            issues.append(.init(field: .model, message: "The selected model is not in this Provider's model list."))
        }

        let rawURL = profile.baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if rawURL.isEmpty {
            issues.append(.init(field: .baseURL, message: "Base URL is required."))
        } else if let components = URLComponents(string: rawURL),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false {
            // Valid provider endpoint.
        } else {
            issues.append(.init(field: .baseURL, message: "Base URL must be a valid HTTPS URL."))
        }

        let environment = profile.apiKeyEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pattern = "^[A-Z][A-Z0-9_]{0,127}$"
        if environment.range(of: pattern, options: .regularExpression) == nil {
            issues.append(.init(field: .apiKeyEnvironment, message: "API key environment variable is required."))
        }

        if wireAPI != "responses", !issues.contains(where: { $0.field == .wireAPI }) {
            issues.append(.init(field: .wireAPI, message: "Only the Responses API is supported by the current Codex version."))
        }
        return issues
    }
}
