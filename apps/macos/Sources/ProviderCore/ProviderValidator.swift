import Foundation

public struct ValidationIssue: Equatable, Sendable {
    public enum Field: String, Sendable {
        case displayName
        case baseURL
        case wireAPI
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

        guard !profile.isBuiltIn else { return issues }

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

        if profile.wireAPI?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            issues.append(.init(field: .wireAPI, message: "API type is required."))
        }
        return issues
    }
}
