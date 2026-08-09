public enum ProviderDefaults {
    public static func profile(for id: ProviderID) -> ProviderProfile {
        switch id {
        case .openAI:
            return ProviderProfile(
                id: .openAI,
                displayName: "OpenAI / ChatGPT",
                baseURL: nil,
                wireAPI: nil,
                model: nil,
                isBuiltIn: true
            )
        case .qilin:
            return ProviderProfile(
                id: .qilin,
                displayName: "Qilin",
                baseURL: "https://www.qilinapi.com",
                wireAPI: "responses",
                model: "gpt-5.5",
                isBuiltIn: false
            )
        case .vectorEngine:
            return ProviderProfile(
                id: .vectorEngine,
                displayName: "VectorEngine",
                baseURL: "https://api.vectorengine.cn/v1",
                wireAPI: "responses",
                model: "gpt-5.5",
                isBuiltIn: false
            )
        }
    }

    public static var all: [ProviderProfile] {
        ProviderID.allCases.map(profile(for:))
    }
}
