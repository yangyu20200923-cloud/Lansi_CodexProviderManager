import Foundation
import XCTest

final class LocalizationResourceTests: XCTestCase {
    func testEnglishAndChineseKeySetsMatch() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
        let english = try String(contentsOf: root.appendingPathComponent("en.lproj/Localizable.strings"))
        let chinese = try String(contentsOf: root.appendingPathComponent("zh-Hans.lproj/Localizable.strings"))
        XCTAssertEqual(keys(in: english), keys(in: chinese))
        XCTAssertEqual(placeholders(in: english), placeholders(in: chinese))
    }

    private func keys(in text: String) -> Set<String> {
        Set(text.split(separator: "\n").compactMap { line in
            let value = line.trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\"") else { return nil }
            return value.split(separator: "\"", omittingEmptySubsequences: false).dropFirst().first.map(String.init)
        })
    }

    private func placeholders(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"%(?:\d+\$)?[@d]"#)
        return text.split(separator: "\n").flatMap { line -> [String] in
            let value = String(line)
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            return regex.matches(in: value, range: range).compactMap {
                Range($0.range, in: value).map { String(value[$0]) }
            }
        }.sorted()
    }
}
