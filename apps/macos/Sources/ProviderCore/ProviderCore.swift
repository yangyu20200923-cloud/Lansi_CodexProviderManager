public enum ProviderID: String, CaseIterable, Codable, Sendable {
    case openAI = "openai"
    case qilin = "qilin"
    case vectorEngine = "vectorengine"
}
