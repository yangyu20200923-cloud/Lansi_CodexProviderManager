import Foundation

public enum ChatGPTServiceError: Error, Equatable {
    case commandFailed(String)
    case timeout
}

public final class ChatGPTService: @unchecked Sendable {
    public init() {}

    public func quit() async throws {
        try run("/usr/bin/osascript", ["-e", "tell application \"ChatGPT\" to quit"])
    }

    public func waitUntilQuiescent(timeout: TimeInterval = 15) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            process.arguments = ["-x", "ChatGPT"]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        throw ChatGPTServiceError.timeout
    }

    public func launch() async throws {
        try run("/usr/bin/open", ["-a", "ChatGPT"])
    }

    public func setEnvironment(profile: ProviderProfile, key: String?) throws {
        let variables = ["QILIN_API_KEY", "VECTORENGINE_API_KEY"]
        for variable in variables { try run("/bin/launchctl", ["unsetenv", variable], acceptFailure: true) }
        guard !profile.isBuiltIn, let key, let variable = profile.apiKeyEnvironment else { return }
        try run("/bin/launchctl", ["setenv", variable, key])
    }

    private func run(_ executable: String, _ arguments: [String], acceptFailure: Bool = false) throws {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardError = errorPipe
        try process.run()
        process.waitUntilExit()
        guard acceptFailure || process.terminationStatus == 0 else {
            let detail = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? executable
            throw ChatGPTServiceError.commandFailed(detail.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
