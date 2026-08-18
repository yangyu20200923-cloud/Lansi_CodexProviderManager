import Foundation
import XCTest
@testable import ProviderCore

final class SessionCompatServiceTests: XCTestCase {
    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeSession(_ home: URL, relativePath: String, content: String) throws -> URL {
        let file = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    private func reasoningLine(id: String, text: String) -> String {
        """
        {"type":"response_item","payload":{"type":"reasoning","id":"\(id)","summary":[],"content":[{"type":"reasoning_text","text":"\(text)"}],"encrypted_content":"c2VjcmV0"}}
        """
    }

    func testNormalizesPlaintextReasoningContentPreservingOtherLines() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try writeSession(
            home,
            relativePath: "sessions/2026/08/17/rollout.jsonl",
            content: """
            {"type":"session_meta","payload":{"id":"t","session_id":"t","model_provider":"custom_deepseek","cwd":"/tmp"}}
            \(reasoningLine(id: "r1", text: "plaintext thinking"))
            {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"answer"}]}}
            """
        )

        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()

        XCTAssertEqual(summary.filesScanned, 1)
        XCTAssertEqual(summary.normalizedFiles, 1)
        XCTAssertEqual(summary.normalizedItems, 1)
        XCTAssertTrue(summary.skippedFiles.isEmpty)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].contains("session_meta"))
        XCTAssertTrue(lines[1].contains("\"content\":[]"))
        XCTAssertTrue(lines[1].contains("\"encrypted_content\":null"))
        XCTAssertFalse(lines[1].contains("plaintext thinking"))
        XCTAssertTrue(lines[2].contains("\"output_text\""))
    }

    func testNormalizationIsIdempotent() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let file = try writeSession(
            home,
            relativePath: "sessions/2026/rollout.jsonl",
            content: reasoningLine(id: "r1", text: "thinking") + "\n"
        )

        let service = SessionCompatService(codexHome: home)
        XCTAssertEqual(try service.normalizeReasoningContent().normalizedItems, 1)
        XCTAssertEqual(try service.normalizeReasoningContent().normalizedItems, 0)
        _ = file
    }

    func testLeavesOfficialReasoningItemsUntouched() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = """
        {"type":"response_item","payload":{"type":"reasoning","id":"official","summary":[{"type":"summary_text","text":"brief"}],"content":[],"encrypted_content":"ZW5jcnlwdGVk"}}
        """
        let file = try writeSession(home, relativePath: "sessions/2026/official.jsonl", content: original + "\n")

        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()

        XCTAssertEqual(summary.normalizedFiles, 0)
        XCTAssertEqual(summary.normalizedItems, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), original + "\n")
    }

    func testSkipsMalformedLinesAndPreservesThem() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let malformed = "not-json-at-all"
        let file = try writeSession(
            home,
            relativePath: "sessions/2026/rollout.jsonl",
            content: malformed + "\n" + reasoningLine(id: "r1", text: "x") + "\n"
        )

        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()

        XCTAssertEqual(summary.normalizedItems, 1)
        let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
        XCTAssertEqual(lines[0], malformed)
    }

    func testScansNestedDirectoriesAndPreservesCRLFAndPermissions() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let nested = home.appendingPathComponent("sessions/2026/08/17/rollout.jsonl")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let crlf = reasoningLine(id: "r1", text: "crlf thinking") + "\r\n"
        try crlf.write(to: nested, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: nested.path)

        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()

        XCTAssertEqual(summary.normalizedItems, 1)
        let data = try Data(contentsOf: nested)
        XCTAssertTrue(data.contains(Data("\"content\":[]".utf8)))
        XCTAssertTrue(data.contains(Data("\r\n".utf8)))
        let permissions = try FileManager.default.attributesOfItem(atPath: nested.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testMissingSessionsDirectoryIsNoOp() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()
        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.normalizedItems, 0)
    }

    func testNonJSONLFilesAreIgnored() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let text = home.appendingPathComponent("sessions/2026/notes.txt")
        try FileManager.default.createDirectory(at: text.deletingLastPathComponent(), withIntermediateDirectories: true)
        try reasoningLine(id: "r1", text: "ignored").write(to: text, atomically: true, encoding: .utf8)

        let summary = try SessionCompatService(codexHome: home).normalizeReasoningContent()

        XCTAssertEqual(summary.filesScanned, 0)
        XCTAssertEqual(summary.normalizedItems, 0)
    }
}
