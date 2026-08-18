import Foundation
import XCTest
@testable import ProviderCore

final class ModelCatalogServiceTests: XCTestCase {
    func testModelsURLAppendsModelsToVersionedBaseURL() {
        XCTAssertEqual(
            ModelCatalogService.modelsURL(baseURL: "https://api.example.com/v1")?.absoluteString,
            "https://api.example.com/v1/models"
        )
        XCTAssertEqual(
            ModelCatalogService.modelsURL(baseURL: "https://api.example.com/v1/models")?.absoluteString,
            "https://api.example.com/v1/models"
        )
    }

    func testParseSupportsOpenAICompatibleDataEnvelopeAndDeduplicates() throws {
        let data = Data(#"{"data":[{"id":"deepseek-chat"},{"id":"deepseek-reasoner"},{"id":"deepseek-chat"}]}"#.utf8)
        XCTAssertEqual(try ModelCatalogService.parse(data: data), ["deepseek-chat", "deepseek-reasoner"])
    }

    func testParseSupportsSimpleArrayResponse() throws {
        let data = Data(#"[{"id":"model-a"},{"id":"model-b"}]"#.utf8)
        XCTAssertEqual(try ModelCatalogService.parse(data: data), ["model-a", "model-b"])
    }

    func testCuratedModelsDropsNonLLMEntriesAndKeepsSelectedModel() {
        let messy = [
            "gpt-5-chat", "qwen3-coder", "o1", "deepseek-v4-flash-0731",
            "suno_lyrics", "doubao-seedream-5-0-260128", "text-embedding-3-large",
            "gpt-5.5", "flux-pro",
        ]
        let curated = ModelCatalogService.curatedModels(messy, alwaysInclude: ["gpt-5.5"])
        XCTAssertEqual(curated, ["gpt-5.5", "gpt-5-chat", "qwen3-coder", "o1", "deepseek-v4-flash-0731"])
    }

    func testCuratedModelsFallsBackToOriginalListWhenNothingMatches() {
        let exotic = ["custom-model-a", "custom-model-b"]
        XCTAssertEqual(ModelCatalogService.curatedModels(exotic), exotic)
    }

    func testFullCatalogKeepsEveryUpstreamModelAndDeduplicatesConfiguredPrimary() {
        let upstream = ["gpt-5.6-sol-max", "seedream-5", "text-embedding-3-large", "gpt-5.6-sol-max"]
        XCTAssertEqual(
            ModelCatalogService.fullCatalog(upstream, alwaysInclude: ["custom-primary"]),
            ["custom-primary", "gpt-5.6-sol-max", "seedream-5", "text-embedding-3-large"]
        )
    }

    func testMatchingFiltersDisplayOnlyAndPreservesFullCatalog() {
        let models = ["gpt-5.6-sol-max", "qwen3-coder", "qwen3-vl", "seedream-5"]
        XCTAssertEqual(ModelCatalogService.matching(models, query: "QWEN"), ["qwen3-coder", "qwen3-vl"])
        XCTAssertEqual(ModelCatalogService.matching(models, query: ""), models)
        XCTAssertEqual(models, ["gpt-5.6-sol-max", "qwen3-coder", "qwen3-vl", "seedream-5"])
    }
}
