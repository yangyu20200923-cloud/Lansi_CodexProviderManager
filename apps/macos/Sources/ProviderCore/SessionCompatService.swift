import Foundation

public struct SessionCompatSummary: Equatable, Sendable {
    public let filesScanned: Int
    public let normalizedFiles: Int
    public let normalizedItems: Int
    public let skippedFiles: [String]

    public init(filesScanned: Int, normalizedFiles: Int, normalizedItems: Int, skippedFiles: [String] = []) {
        self.filesScanned = filesScanned
        self.normalizedFiles = normalizedFiles
        self.normalizedItems = normalizedItems
        self.skippedFiles = skippedFiles
    }
}

public enum SessionCompatError: Error, Equatable {
    case writeFailed(String)
}

/// Keeps existing conversations replayable after a Provider switch.
///
/// Third-party `/v1/responses` sources can return `reasoning` items with
/// plaintext `content`, and Codex stores those items verbatim in rollout logs.
/// The upstream Responses API requires `reasoning.content` to be an empty array
/// when history is replayed, so switching from such a source to a strictly
/// validating Provider fails with `array_above_max_length`. Normalizing the
/// stored items makes every rollout safe to replay under any Provider without
/// deleting or rewriting any conversation content.
public final class SessionCompatService: @unchecked Sendable {
    public let codexHome: URL

    public init(codexHome: URL) {
        self.codexHome = codexHome
    }

    @discardableResult
    public func normalizeReasoningContent() throws -> SessionCompatSummary {
        let sessionsRoot = codexHome.appendingPathComponent("sessions")
        guard FileManager.default.fileExists(atPath: sessionsRoot.path),
              let enumerator = FileManager.default.enumerator(
                  at: sessionsRoot,
                  includingPropertiesForKeys: [.isRegularFileKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return SessionCompatSummary(filesScanned: 0, normalizedFiles: 0, normalizedItems: 0)
        }
        var rolloutFiles: [URL] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "jsonl" else { continue }
            rolloutFiles.append(file)
        }
        // A real Codex home can hold gigabytes of rollout logs; scan them in
        // parallel so a switch does not sit silently for a minute before the
        // first user-visible step completes.
        let lock = NSLock()
        var scanned = 0
        var normalizedFiles = 0
        var normalizedItems = 0
        var skipped: [String] = []
        DispatchQueue.concurrentPerform(iterations: rolloutFiles.count) { index in
            let file = rolloutFiles[index]
            lock.lock()
            scanned += 1
            lock.unlock()
            do {
                let count = try normalizeFile(file)
                if count > 0 {
                    lock.lock()
                    normalizedFiles += 1
                    normalizedItems += count
                    lock.unlock()
                }
            } catch {
                lock.lock()
                skipped.append(file.lastPathComponent)
                lock.unlock()
            }
        }
        return SessionCompatSummary(
            filesScanned: scanned,
            normalizedFiles: normalizedFiles,
            normalizedItems: normalizedItems,
            skippedFiles: skipped
        )
    }

    /// Rewrites a rollout file in place (atomically) when it contains reasoning
    /// items with non-empty `content`. Files without such items are left
    /// untouched. Malformed lines are preserved verbatim.
    private func normalizeFile(_ file: URL) throws -> Int {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        let temporary = file.deletingLastPathComponent()
            .appendingPathComponent(".session-compat-\(UUID().uuidString).jsonl")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw SessionCompatError.writeFailed(file.path)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            if let permissions = attributes?[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            var normalized = 0
            var buffer = Data()
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                buffer.append(chunk)
                var start = buffer.startIndex
                while let newline = buffer[start...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    let hasCarriageReturn = line.last == 0x0D
                    let body = hasCarriageReturn ? line.dropLast() : line
                    if let updated = try? normalizedLine(body) {
                        normalized += 1
                        try output.write(contentsOf: updated)
                        try output.write(contentsOf: hasCarriageReturn ? Data([0x0D, 0x0A]) : Data([0x0A]))
                    } else {
                        try output.write(contentsOf: line)
                        try output.write(contentsOf: Data([0x0A]))
                    }
                    start = newline + 1
                }
                buffer.removeSubrange(..<start)
            }
            if !buffer.isEmpty {
                if let updated = try? normalizedLine(buffer) {
                    normalized += 1
                    try output.write(contentsOf: updated)
                } else {
                    try output.write(contentsOf: buffer)
                }
            }
            try output.synchronize()
            if normalized > 0 {
                _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            }
            return normalized
        } catch {
            throw SessionCompatError.writeFailed(file.path)
        }
    }

    /// Returns the normalized form of one rollout line when it is a `reasoning`
    /// item with non-empty plaintext `content`; `nil` when the line needs no
    /// change or cannot be parsed.
    private func normalizedLine(_ body: Data) throws -> Data? {
        guard !body.isEmpty,
              var object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["type"] as? String == "response_item",
              var payload = object["payload"] as? [String: Any],
              payload["type"] as? String == "reasoning" else {
            return nil
        }
        let content = payload["content"]
        let isNonEmpty: Bool
        if let array = content as? [Any] {
            isNonEmpty = !array.isEmpty
        } else if let string = content as? String {
            isNonEmpty = !string.isEmpty
        } else {
            isNonEmpty = false
        }
        guard isNonEmpty else { return nil }
        payload["content"] = []
        payload["encrypted_content"] = NSNull()
        object["payload"] = payload
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
