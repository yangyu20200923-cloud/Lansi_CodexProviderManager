import Foundation

public struct ProviderID: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String

    public init?(rawValue: String) {
        guard !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let rawValue = try decoder.singleValueContainer().decode(String.self)
        guard let value = ProviderID(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Provider id is required."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let openAI = ProviderID(rawValue: "openai")!
    public static let qilin = ProviderID(rawValue: "qilin")!
    public static let vectorEngine = ProviderID(rawValue: "vectorengine")!
    public static let builtInIDs = [openAI, qilin, vectorEngine]

    public static func custom() -> ProviderID {
        ProviderID(rawValue: UUID().uuidString.lowercased())!
    }

    public var isBuiltIn: Bool { Self.builtInIDs.contains(self) }
}
