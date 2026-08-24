import AppKit
import Foundation

public enum ChatGPTServiceError: Error, Equatable, LocalizedError {
    case commandFailed(String)
    case timeout
    case codexExecutableUnavailable
    case configurationVerificationFailed
    case runtimeEnvironmentVerificationFailed
    case launchFailed

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let message): return message
        case .timeout: return "ChatGPT did not close cleanly. Close ChatGPT normally, wait for it to exit, then retry the Provider switch."
        case .codexExecutableUnavailable: return "The bundled Codex executable is unavailable."
        case .configurationVerificationFailed: return "Codex did not load the selected Provider configuration and authentication."
        case .runtimeEnvironmentVerificationFailed: return "The restarted Codex desktop runtime did not inherit the selected Provider API key."
        case .launchFailed: return "The ChatGPT app did not restart after the Provider switch. Open ChatGPT manually and try the switch again."
        }
    }
}

public final class ChatGPTService: ProviderRuntimeControlling, @unchecked Sendable {
    typealias ProcessTableProvider = () throws -> [ProcessRecord]
    typealias OpenRunner = ([String]) throws -> Void

    struct ProcessRecord: Equatable {
        let pid: Int32
        let parentPID: Int32
        let command: String
        let arguments: String

        var commandLine: String {
            let suffix = arguments.isEmpty ? "" : " " + arguments
            return "\(pid) \(parentPID) \(command)\(suffix)"
        }
    }

    private var processTableProvider: ProcessTableProvider
    private var openRunner: OpenRunner
    private var launchProbeTimeout: TimeInterval = 6

    public init() {
        self.processTableProvider = { try Self.systemProcessTable() }
        self.openRunner = { try Self.runOpen($0) }
    }

    func configureForTesting(
        processTableProvider: @escaping ProcessTableProvider,
        openRunner: @escaping OpenRunner,
        launchProbeTimeout: TimeInterval = 6
    ) {
        self.processTableProvider = processTableProvider
        self.openRunner = openRunner
        self.launchProbeTimeout = launchProbeTimeout
    }

    public func quit() async throws {
        // Ask the macOS application to quit cleanly. Do not signal or kill the
        // Codex process tree: doing so tears down every active conversation's
        // transport and makes the restarted desktop app reconnect all threads.
        // A switch may only continue after the normal quit has released the
        // main app and its managed app-server.
        let records = try processTableProvider()
        let mainProcessIDs = records.filter { Self.isChatGPTProcess($0) }.map(\.pid)
        for pid in mainProcessIDs.sorted(by: >) {
            guard let application = NSRunningApplication(processIdentifier: pid_t(pid)), application.terminate() else {
                throw ChatGPTServiceError.commandFailed("ChatGPT did not accept a normal quit request. Close ChatGPT normally, then retry the Provider switch.")
            }
        }
    }

    public func waitUntilQuiescent(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try Self.chatGPTRuntimeProcessIDs(from: processTableProvider()).isEmpty { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ChatGPTServiceError.timeout
    }

    public func launch() async throws {
        // LaunchServices can treat a recently killed app as still running
        // (leftover helpers keep its registration alive), in which case
        // `open -a ChatGPT` only activates and never starts the app. Poll for
        // the main process, retry, and fall back to a forced new instance so
        // the switch always restarts the runtime.
        for attempt in 0..<3 {
            try openRunner(attempt == 2 ? ["-n", "-a", "ChatGPT"] : ["-a", "ChatGPT"])
            if try await waitForMainProcess(timeout: launchProbeTimeout) { return }
        }
        throw ChatGPTServiceError.launchFailed
    }

    public func setEnvironment(profile: ProviderProfile, key: String?) throws {
        try setEnvironment(
            profile: profile,
            key: key,
            clearing: [ProviderDefaults.profile(for: .qilin), ProviderDefaults.profile(for: .vectorEngine)]
        )
    }

    public func setEnvironment(profile: ProviderProfile, key: String?, clearing profiles: [ProviderProfile]) throws {
        var variables = Set(["QILIN_API_KEY", "VECTORENGINE_API_KEY"])
        for candidate in profiles {
            if let variable = candidate.apiKeyEnvironment?.trimmingCharacters(in: .whitespacesAndNewlines), !variable.isEmpty {
                variables.insert(variable)
            }
        }
        for variable in variables { try run("/bin/launchctl", ["unsetenv", variable], acceptFailure: true) }
        guard profile.requiresAPIKey, let key, let variable = profile.apiKeyEnvironment else { return }
        try run("/bin/launchctl", ["setenv", variable, key])
    }

    public func verifyConfiguration(codexHome: URL, profile: ProviderProfile, key: String?) throws {
        guard let codexExecutable = Self.codexExecutable() else {
            throw ChatGPTServiceError.codexExecutableUnavailable
        }
        if profile.requiresAPIKey && (key?.isEmpty != false || profile.apiKeyEnvironment?.isEmpty != false) {
            throw ChatGPTServiceError.configurationVerificationFailed
        }
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = codexHome.path
        if let key, let variable = profile.apiKeyEnvironment {
            environment[variable] = key
        }
        // doctor may exit non-zero when an advisory check (for example the
        // terminal environment) fails even though the JSON report is green;
        // the report body is the source of truth, so failures are accepted
        // and validated from the JSON.
        let captured = try Self.runCaptured(
            codexExecutable,
            ["--strict-config", "doctor", "--json"],
            environment: environment,
            acceptFailure: true
        )
        guard let reportData = captured.output.data(using: .utf8) else {
            throw ChatGPTServiceError.configurationVerificationFailed
        }
        try Self.verifyDoctorOutput(reportData, expectedProvider: profile.configProviderID)
    }

    public func verifyLaunchedRuntime(profile: ProviderProfile) async throws {
        guard profile.requiresAPIKey, let variable = profile.apiKeyEnvironment else { return }
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            let processIDs = try runningCodexAppServerProcessIDs()
            if try processIDs.contains(where: { try processEnvironmentContains(name: variable, processID: $0) }) {
                return
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ChatGPTServiceError.runtimeEnvironmentVerificationFailed
    }

    /// Waits for the ChatGPT main process to appear after `open` was asked to
    /// start it. Returns `false` when the timeout expires so `launch()` can
    /// retry with a stronger invocation.
    private func waitForMainProcess(timeout: TimeInterval) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try processTableProvider().contains(where: { Self.isChatGPTProcess($0) }) {
                return true
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// Confirms that Codex loaded the requested Provider. Network preflight warnings are advisory:
    /// Codex may reconnect or fall back to another transport before a session is usable. `doctor`
    /// returns a non-zero status when any independent diagnostic fails (for example, terminal
    /// environment inspection), so the JSON checks are the source of truth for switch safety.
    static func verifyDoctorOutput(_ data: Data, expectedProvider: String) throws {
        guard let report = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTServiceError.configurationVerificationFailed
        }
        try verifyDoctorReport(report, expectedProvider: expectedProvider)
    }

    static func verifyDoctorReport(_ report: [String: Any], expectedProvider: String) throws {
        guard let checks = report["checks"] as? [String: Any],
              let configLoad = checks["config.load"] as? [String: Any],
              configLoad["status"] as? String == "ok",
              let details = configLoad["details"] as? [String: Any],
              details["model provider"] as? String == expectedProvider,
              let authentication = checks["auth.credentials"] as? [String: Any],
              authentication["status"] as? String == "ok" else {
            throw ChatGPTServiceError.configurationVerificationFailed
        }
    }

    static func codexExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundledPath: String = "/Applications/ChatGPT.app/Contents/Resources/codex",
        fileManager: FileManager = .default
    ) -> String? {
        if fileManager.isExecutableFile(atPath: bundledPath) { return bundledPath }
        guard let path = environment["PATH"] else { return nil }
        return path.split(separator: ":").map { String($0) + "/codex" }.first {
            fileManager.isExecutableFile(atPath: $0)
        }
    }

    private func runningCodexAppServerProcessIDs() throws -> [String] {
        try Self.chatGPTRuntimeProcessIDs(from: processTableProvider())
            .compactMap(String.init)
    }

    private static func systemProcessTable() throws -> [ProcessRecord] {
        try commandOutput("/bin/ps", ["-axo", "pid=,ppid=,args="])
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.parseProcessRecord(String($0)) }
    }

    static func isChatGPTProcess(_ process: String) -> Bool {
        parseProcessRecord(process).map(isChatGPTProcess) ?? false
    }

    static func isCodexAppServerProcess(_ process: String) -> Bool {
        parseProcessRecord(process).map(isCodexAppServerProcess) ?? false
    }

    static func parseProcessRecord(_ process: String) -> ProcessRecord? {
        let parts = process.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 3,
              let pid = Int32(parts[0]),
              let parentPID = Int32(parts[1]) else { return nil }
        let commandAndArguments = String(parts[2])
        let commandParts = commandAndArguments.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let command = commandParts.first else { return nil }
        return ProcessRecord(
            pid: pid,
            parentPID: parentPID,
            command: String(command),
            arguments: commandParts.count > 1 ? String(commandParts[1]) : ""
        )
    }

    static func isChatGPTProcess(_ process: ProcessRecord) -> Bool {
        process.command == "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"
    }

    static func isCodexAppServerProcess(_ process: ProcessRecord) -> Bool {
        // ChatGPT owns the app-server started with its analytics/default
        // runtime flags. Computer Use and other tools may start independent
        // `codex app-server --listen stdio://` processes from the same binary;
        // those must not block Provider Manager from switching.
        process.command.hasSuffix("/Contents/Resources/codex")
            && process.arguments.contains("app-server")
            && process.arguments.contains("--analytics-default-enabled")
    }

    /// True for any process owned by the ChatGPT desktop app, including its
    /// crashpad, renderer, and helper processes. Independent `codex
    /// app-server --listen stdio://` sessions that happen to run from the same
    /// bundled binary are deliberately excluded: killing them would terminate
    /// unrelated CLI conversations.
    static func isChatGPTOwnedProcess(_ process: ProcessRecord) -> Bool {
        guard process.command.hasPrefix("/Applications/ChatGPT.app/") else { return false }
        if process.command.hasSuffix("/Contents/Resources/codex") {
            return process.arguments.contains("--analytics-default-enabled")
        }
        return true
    }

    static func chatGPTRuntimeProcessIDs(from records: [ProcessRecord]) -> [Int32] {
        let chatGPTPIDs = Set(records.filter(isChatGPTProcess).map(\.pid))
        let appServerPIDs = records
            .filter(isCodexAppServerProcess)
            .map(\.pid)
        return Array(chatGPTPIDs.union(appServerPIDs)).sorted()
    }

    /// Full ChatGPT process ownership is retained for diagnostics only. It is
    /// intentionally not used to force a Provider switch, because helper and
    /// renderer termination can interrupt unrelated in-flight conversations.
    static func chatGPTOwnedProcessIDs(from records: [ProcessRecord]) -> [Int32] {
        records.filter(isChatGPTOwnedProcess).map(\.pid).sorted()
    }

    private func processEnvironmentContains(name: String, processID: String) throws -> Bool {
        let output = try Self.commandOutput("/bin/ps", ["eww", "-p", processID, "-o", "command="], acceptFailure: true)
        return Self.environmentOutput(output, contains: name)
    }

    static func environmentOutput(_ output: String, contains name: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        return output.range(of: "(?:^|\\s)\(escaped)=", options: .regularExpression) != nil
    }

    private static func runOpen(_ arguments: [String]) throws {
        _ = try runCaptured("/usr/bin/open", arguments)
    }

    private func run(_ executable: String, _ arguments: [String], acceptFailure: Bool = false) throws {
        _ = try Self.commandOutput(executable, arguments, acceptFailure: acceptFailure)
    }

    static func commandOutput(_ executable: String, _ arguments: [String], acceptFailure: Bool = false) throws -> String {
        try runCaptured(executable, arguments, acceptFailure: acceptFailure).output
    }

    /// Runs one short-lived command with stdout/stderr captured through
    /// temporary files. Pipes are deliberately avoided: a command whose
    /// output exceeds the 64 KB pipe buffer (for example
    /// `ps -axo pid=,ppid=,args=` on a loaded machine) would block the child
    /// while the parent waits for exit, deadlocking the switch.
    static func runCaptured(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        acceptFailure: Bool = false
    ) throws -> (output: String, status: Int32) {
        let process = Process()
        let directory = FileManager.default.temporaryDirectory
        let outputURL = directory.appendingPathComponent("cpm-out-\(UUID().uuidString).log")
        let errorURL = directory.appendingPathComponent("cpm-err-\(UUID().uuidString).log")
        defer {
            try? FileManager.default.removeItem(at: outputURL)
            try? FileManager.default.removeItem(at: errorURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        if let environment {
            process.environment = environment
        }
        try process.run()
        process.waitUntilExit()
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
        guard acceptFailure || process.terminationStatus == 0 else {
            let detail = error.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ChatGPTServiceError.commandFailed(detail.isEmpty ? executable : detail)
        }
        return (output, process.terminationStatus)
    }
}
