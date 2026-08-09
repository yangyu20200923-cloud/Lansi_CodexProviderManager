import XCTest
@testable import ProviderCore

final class LanguageStoreTests: XCTestCase {
    private func makeDefaults() -> UserDefaults { UserDefaults(suiteName: "test-language-\(UUID().uuidString)")! }

    func testInvalidValueFallsBackToSystem() {
        let defaults = makeDefaults()
        defaults.set("invalid", forKey: LanguageStore.key)
        XCTAssertEqual(LanguageStore(defaults: defaults).selected, .system)
    }

    func testSystemResolution() {
        let defaults = makeDefaults()
        let store = LanguageStore(defaults: defaults)
        XCTAssertEqual(store.resolvedLocale(preferredLanguages: ["zh-CN"]).identifier, "zh-Hans")
        XCTAssertEqual(store.resolvedLocale(preferredLanguages: ["zh-SG"]).identifier, "zh-Hans")
        XCTAssertEqual(store.resolvedLocale(preferredLanguages: ["fr-FR"]).identifier, "en")
    }

    func testExplicitLanguagePersists() {
        let defaults = makeDefaults()
        let store = LanguageStore(defaults: defaults)
        store.save(.english)
        XCTAssertEqual(store.selected, .english)
        XCTAssertEqual(store.resolvedLocale().identifier, "en")
    }
}
