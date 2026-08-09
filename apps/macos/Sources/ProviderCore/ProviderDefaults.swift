public enum ProviderDefaults {
    public static func profile(for id: ProviderID) -> ProviderProfile {
        if id == .openAI {
            return ProviderProfile(
                id: .openAI,
                displayName: "OpenAI / ChatGPT",
                baseURL: nil,
                wireAPI: nil,
                model: nil,
                isBuiltIn: true
            )
        }
        if id == .qilin {
            return ProviderProfile(
                id: .qilin,
                displayName: "Qilin",
                baseURL: "https://www.qilinapi.com/v1",
                wireAPI: "responses",
                apiKeyEnvironment: "QILIN_API_KEY",
                model: "gpt-5.5",
                isBuiltIn: false
            )
        }
        if id == .vectorEngine {
            return ProviderProfile(
                id: .vectorEngine,
                displayName: "VectorEngine",
                baseURL: "https://api.vectorengine.cn/v1",
                wireAPI: "responses",
                apiKeyEnvironment: "VECTORENGINE_API_KEY",
                model: "gpt-5.5",
                isBuiltIn: false
            )
        }
        return ProviderProfile(
            id: id,
            displayName: "Custom Provider",
            baseURL: nil,
            wireAPI: "responses",
            apiKeyEnvironment: nil,
            model: nil,
            isBuiltIn: false
        )
    }

    public static var all: [ProviderProfile] {
        ProviderID.builtInIDs.map(profile(for:))
    }
}
