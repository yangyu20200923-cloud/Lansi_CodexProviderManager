import Foundation
import XCTest
@testable import ProviderCore

final class ChatGPTServiceTests: XCTestCase {
    func testCodexExecutablePrefersBundledChatGPTCLIWithoutPATH() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        XCTAssertEqual(
            ChatGPTService.codexExecutable(environment: [:], bundledPath: executable.path),
            executable.path
        )
    }

    func testDoctorReportAllowsOpenAIWhenResponsesWebSocketCheckWarns() throws {
        let report = doctorReport(provider: "openai", webSocketStatus: "warning", webSocketSummary: "Responses WebSocket failed; HTTPS fallback may still work")

        XCTAssertNoThrow(try ChatGPTService.verifyDoctorReport(report, expectedProvider: "openai"))
    }

    func testDoctorReportAllowsOpenAIWhenWebSocketCheckIsHealthy() throws {
        let report = doctorReport(provider: "openai", webSocketStatus: "ok", webSocketSummary: "Responses WebSocket is reachable")

        XCTAssertNoThrow(try ChatGPTService.verifyDoctorReport(report, expectedProvider: "openai"))
    }

    func testDoctorOutputAllowsRequiredChecksWhenAnUnrelatedCheckMakesDoctorExitNonzero() throws {
        var report = doctorReport(provider: "custom_deepseek", webSocketStatus: "ok", webSocketSummary: "WebSocket is disabled")
        var checks = report["checks"] as! [String: Any]
        checks["terminal.env"] = ["status": "fail", "summary": "Terminal environment could not be inspected"]
        report["checks"] = checks

        let data = try JSONSerialization.data(withJSONObject: report)

        XCTAssertNoThrow(try ChatGPTService.verifyDoctorOutput(data, expectedProvider: "custom_deepseek"))
    }

    func testDoctorOutputRejectsMalformedJSON() {
        XCTAssertThrowsError(try ChatGPTService.verifyDoctorOutput(Data("not-json".utf8), expectedProvider: "openai"))
    }

    func testDoctorReportRejectsSelectedProviderWithoutAuthentication() {
        var report = doctorReport(provider: "qilin", webSocketStatus: "ok", webSocketSummary: "WebSocket is disabled")
        var checks = report["checks"] as! [String: Any]
        checks["auth.credentials"] = ["status": "fail", "summary": "active model provider auth env var is missing"]
        report["checks"] = checks

        XCTAssertThrowsError(try ChatGPTService.verifyDoctorReport(report, expectedProvider: "qilin"))
    }

    func testEnvironmentOutputDetectsOnlyWholeEnvironmentVariableNames() {
        XCTAssertTrue(ChatGPTService.environmentOutput("command QILIN_API_KEY=present", contains: "QILIN_API_KEY"))
        XCTAssertFalse(ChatGPTService.environmentOutput("command NOT_QILIN_API_KEY=present", contains: "QILIN_API_KEY"))
    }

    func testProcessDetectionUsesAbsoluteChatGPTAndCodexAppServerCommands() {
        XCTAssertTrue(ChatGPTService.isChatGPTProcess("10608 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT"))
        XCTAssertFalse(ChatGPTService.isChatGPTProcess("10608 1 /Applications/ChatGPT.app/Contents/Frameworks/ChatGPT Helper"))
        XCTAssertTrue(ChatGPTService.isCodexAppServerProcess("10641 10608 /Applications/ChatGPT.app/Contents/Resources/codex -c features.code_mode_host=true app-server --analytics-default-enabled"))
        XCTAssertFalse(ChatGPTService.isCodexAppServerProcess("10641 10608 /Applications/ChatGPT.app/Contents/Resources/codex --version"))
        XCTAssertFalse(ChatGPTService.isCodexAppServerProcess("10641 16847 /Applications/ChatGPT.app/Contents/Resources/codex app-server --listen stdio://"))
        XCTAssertFalse(ChatGPTService.isCodexAppServerProcess("10641 10608 /tmp/codex-wrapper app-server --analytics-default-enabled"))
    }

    func testRuntimeProcessSelectionIncludesOnlyChatGPTOwnedAppServer() {
        let records = [
            ChatGPTService.ProcessRecord(
                pid: 16625,
                parentPID: 1,
                command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                arguments: ""
            ),
            ChatGPTService.ProcessRecord(
                pid: 16662,
                parentPID: 16625,
                command: "/Applications/ChatGPT.app/Contents/Resources/codex",
                arguments: "-c features.code_mode_host=true app-server --analytics-default-enabled"
            ),
            ChatGPTService.ProcessRecord(
                pid: 17123,
                parentPID: 16847,
                command: "/Applications/ChatGPT.app/Contents/Resources/codex",
                arguments: "app-server --listen stdio://"
            )
        ]

        XCTAssertEqual(ChatGPTService.chatGPTRuntimeProcessIDs(from: records), [16625, 16662])
    }

    func testOwnedProcessSelectionCoversFullChatGPTProcessTree() {
        let records = [
            ChatGPTService.ProcessRecord(
                pid: 16625,
                parentPID: 1,
                command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                arguments: ""
            ),
            ChatGPTService.ProcessRecord(
                pid: 16662,
                parentPID: 16625,
                command: "/Applications/ChatGPT.app/Contents/Resources/codex",
                arguments: "-c features.code_mode_host=true app-server --analytics-default-enabled"
            ),
            ChatGPTService.ProcessRecord(
                pid: 16670,
                parentPID: 1,
                command: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151.0.7922.137/Helpers/browser_crashpad_handler",
                arguments: "--monitor-self --database=/Users/lansi/Library/Application Support/Codex/Crashpad"
            ),
            ChatGPTService.ProcessRecord(
                pid: 16680,
                parentPID: 16625,
                command: "/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/Versions/151.0.7922.137/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
                arguments: "--type=renderer --user-data-dir=/Users/lansi/Library/Application Support/Codex"
            ),
            ChatGPTService.ProcessRecord(
                pid: 16690,
                parentPID: 16662,
                command: "/Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
                arguments: ""
            ),
            ChatGPTService.ProcessRecord(
                pid: 17123,
                parentPID: 16847,
                command: "/Applications/ChatGPT.app/Contents/Resources/codex",
                arguments: "app-server --listen stdio://"
            ),
            ChatGPTService.ProcessRecord(
                pid: 17130,
                parentPID: 3097,
                command: "/tmp/codex-wrapper",
                arguments: "app-server --analytics-default-enabled"
            )
        ]

        XCTAssertEqual(
            ChatGPTService.chatGPTOwnedProcessIDs(from: records),
            [16625, 16662, 16670, 16680, 16690]
        )
    }

    func testLaunchRetriesOpenAndFallsBackToForcedNewInstance() async throws {
        var openInvocations: [[String]] = []
        var mainProcessVisibleAt: [Int] = [1, 1, 1]
        var visible = false
        let service = ChatGPTService()
        service.configureForTesting(
            processTableProvider: {
                if visible {
                    return [
                        ChatGPTService.ProcessRecord(
                            pid: 20001,
                            parentPID: 1,
                            command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                            arguments: ""
                        )
                    ]
                }
                return []
            },
            openRunner: { arguments in
                openInvocations.append(arguments)
                if openInvocations.count == 3 {
                    visible = true
                }
            },
            launchProbeTimeout: 0.05
        )

        try await service.launch()

        XCTAssertEqual(openInvocations.count, 3)
        XCTAssertEqual(openInvocations[0], ["-a", "ChatGPT"])
        XCTAssertEqual(openInvocations[1], ["-a", "ChatGPT"])
        XCTAssertEqual(openInvocations[2], ["-n", "-a", "ChatGPT"])
    }

    func testLaunchSucceedsOnFirstOpenWhenMainProcessAppears() async throws {
        var openInvocations: [[String]] = []
        let service = ChatGPTService()
        service.configureForTesting(
            processTableProvider: {
                [
                    ChatGPTService.ProcessRecord(
                        pid: 20001,
                        parentPID: 1,
                        command: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
                        arguments: ""
                    )
                ]
            },
            openRunner: { openInvocations.append($0) }
        )

        try await service.launch()

        XCTAssertEqual(openInvocations, [["-a", "ChatGPT"]])
    }

    func testLaunchThrowsWhenMainProcessNeverAppears() async throws {
        let service = ChatGPTService()
        service.configureForTesting(
            processTableProvider: { [] },
            openRunner: { _ in },
            launchProbeTimeout: 0.05
        )

        do {
            try await service.launch()
            XCTFail("launch should have thrown")
        } catch ChatGPTServiceError.launchFailed {
            // Expected.
        }
    }

    /// Regression: `commandOutput` used to wait for exit before draining the
    /// pipe. A command producing more than the 64 KB pipe buffer (the real
    /// `ps -axo pid=,ppid=,args=` table on this machine is ~126 KB) blocked
    /// the child forever, leaving the switch stuck right after "switch start".
    func testCommandOutputCapturesOutputLargerThanPipeBuffer() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("python3 is unavailable")
        }
        let expectation = expectation(description: "large output capture completes")
        var captured: String?
        let queue = DispatchQueue(label: "chatgpt-service-capture-test")
        queue.async {
            captured = try? ChatGPTService.commandOutput(
                "/usr/bin/python3",
                ["-c", "import sys; sys.stdout.write('x' * 300000)"]
            )
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        XCTAssertEqual(captured?.count, 300000)
    }

    /// Regression: `verifyConfiguration` must tolerate a non-zero doctor exit
    /// status (advisory check) while still validating the JSON report.
    func testRunCapturedAcceptsNonZeroExitAndReturnsOutput() throws {
        guard FileManager.default.isExecutableFile(atPath: "/bin/sh") else {
            throw XCTSkip("/bin/sh is unavailable")
        }
        let captured = try ChatGPTService.runCaptured(
            "/bin/sh",
            ["-c", "printf out; printf err >&2; exit 3"],
            acceptFailure: true
        )
        XCTAssertEqual(captured.output, "out")
        XCTAssertEqual(captured.status, 3)
    }

    private func doctorReport(provider: String, webSocketStatus: String, webSocketSummary: String) -> [String: Any] {
        [
            "checks": [
                "config.load": [
                    "status": "ok",
                    "details": ["model provider": provider]
                ],
                "auth.credentials": ["status": "ok"],
                "network.websocket_reachability": [
                    "status": webSocketStatus,
                    "summary": webSocketSummary
                ]
            ]
        ]
    }
}
