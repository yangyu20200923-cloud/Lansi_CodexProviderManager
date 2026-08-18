import CryptoKit
import Foundation

/// Keeps the provider recorded in Codex rollout metadata aligned with the
/// provider stored in state_5.sqlite. Codex prefers the first session_meta
/// record when it resumes a conversation, so changing only the state database
/// leaves existing conversations pinned to the old provider.
public final class SessionMetadataSyncService: @unchecked Sendable {
    public enum SyncError: Error, Equatable {
        case readFailed(String)
        case writeFailed(String)
    }

    private let sessionsRoot: URL

    public init(codexHome: URL) {
        sessionsRoot = codexHome.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Updates the first session_meta record in every rollout. Codex writes
    /// session_meta as the first JSONL record; limiting the edit to that record
    /// avoids parsing or rewriting hundreds of megabytes of conversation data.
    @discardableResult
    public func synchronize(provider: String) throws -> Int {
        guard FileManager.default.fileExists(atPath: sessionsRoot.path) else { return 0 }
        var updatedFiles = 0
        for file in sessionFiles() {
            if try synchronizeFirstSessionMetadata(in: file, provider: provider) {
                updatedFiles += 1
            }
        }
        return updatedFiles
    }

    /// Fails if any rollout's first session_meta advertises a different
    /// provider. Codex consults this record when loading an existing thread.
    public func verify(provider: String) throws {
        for file in sessionFiles() {
            let input: FileHandle
            do {
                input = try FileHandle(forReadingFrom: file)
            } catch {
                throw SyncError.readFailed(file.path)
            }
            defer { try? input.close() }
            do {
                let first = try readFirstLine(from: input).line
                if let current = try sessionMetadataProvider(in: first), current != provider {
                    throw SyncError.readFailed(file.path)
                }
            } catch let error as SyncError {
                throw error
            } catch {
                throw SyncError.readFailed(file.path)
            }
        }
    }

    /// Returns a content digest that ignores only model_provider in the first
    /// session_meta record. The rest of each rollout is hashed as raw bytes, so
    /// large real conversations do not go through JSONSerialization.
    public func normalizedHashes() throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try sessionFiles().map { file in
            (relativePath(for: file), try normalizedHash(of: file))
        })
    }

    private func sessionFiles() -> [URL] {
        (FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: [.isRegularFileKey])?
            .compactMap { $0 as? URL }
            .filter {
                $0.pathExtension == "jsonl"
                    && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }) ?? []
    }

    private func relativePath(for file: URL) -> String {
        let root = sessionsRoot.standardizedFileURL.path + "/"
        return file.standardizedFileURL.path.replacingOccurrences(of: root, with: "")
    }

    private func synchronizeFirstSessionMetadata(in file: URL, provider: String) throws -> Bool {
        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: file)
        } catch {
            throw SyncError.readFailed(file.path)
        }
        defer { try? input.close() }

        let first: (line: Data, remainder: Data)
        do {
            first = try readFirstLine(from: input)
        } catch {
            throw SyncError.readFailed(file.path)
        }
        guard let updatedLine = try rewrittenSessionMetadataLine(first.line, provider: provider) else {
            return false
        }

        let directory = file.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".session-meta-\(UUID().uuidString).tmp")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else {
            throw SyncError.writeFailed(file.path)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }

        do {
            if let permissions = attributes?[.posixPermissions] {
                try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
            }
            let output = try FileHandle(forWritingTo: temporary)
            try output.write(contentsOf: updatedLine)
            try output.write(contentsOf: first.remainder)
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
            return true
        } catch {
            throw SyncError.writeFailed(file.path)
        }
    }

    private func normalizedHash(of file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let first = try readFirstLine(from: input)
        var hasher = SHA256()
        if let normalized = try normalizedSessionMetadataLine(first.line) {
            hasher.update(data: normalized)
        } else {
            hasher.update(data: first.line)
        }
        hasher.update(data: first.remainder)
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reads only through the first newline. Any bytes after that newline in
    /// the current chunk are returned so callers can preserve the file without
    /// seeking or loading the remaining rollout into memory.
    private func readFirstLine(from handle: FileHandle) throws -> (line: Data, remainder: Data) {
        var line = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if let newline = chunk.firstIndex(of: 0x0A) {
                line.append(chunk[...newline])
                let remainderStart = chunk.index(after: newline)
                return (line, Data(chunk[remainderStart...]))
            }
            line.append(chunk)
        }
        return (line, Data())
    }

    private func rewrittenSessionMetadataLine(_ line: Data, provider: String) throws -> Data? {
        guard var object = try sessionMetadataObject(in: line) else { return nil }
        guard try sessionMetadataProvider(in: line) != provider else { return nil }
        setProvider(provider, in: &object)
        return try renderedLine(object, lineEnding: lineEnding(of: line))
    }

    private func normalizedSessionMetadataLine(_ line: Data) throws -> Data? {
        guard var object = try sessionMetadataObject(in: line) else { return nil }
        removeProvider(from: &object)
        return try renderedLine(object, lineEnding: lineEnding(of: line))
    }

    private func sessionMetadataObject(in line: Data) throws -> [String: Any]? {
        var body = line
        while body.last == 0x0A || body.last == 0x0D {
            body.removeLast()
        }
        guard !body.isEmpty,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["type"] as? String == "session_meta" else {
            return nil
        }
        return object
    }

    private func sessionMetadataProvider(in line: Data) throws -> String? {
        guard let object = try sessionMetadataObject(in: line) else { return nil }
        if let provider = object["model_provider"] as? String { return provider }
        if let payload = object["payload"] as? [String: Any] {
            return payload["model_provider"] as? String
        }
        return nil
    }

    private func setProvider(_ provider: String, in object: inout [String: Any]) {
        if var payload = object["payload"] as? [String: Any] {
            payload["model_provider"] = provider
            object["payload"] = payload
        } else {
            object["model_provider"] = provider
        }
    }

    private func removeProvider(from object: inout [String: Any]) {
        object.removeValue(forKey: "model_provider")
        if var payload = object["payload"] as? [String: Any] {
            payload.removeValue(forKey: "model_provider")
            object["payload"] = payload
        }
    }

    private func renderedLine(_ object: [String: Any], lineEnding: Data) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        data.append(lineEnding)
        return data
    }

    private func lineEnding(of line: Data) -> Data {
        if line.suffix(2).elementsEqual([0x0D, 0x0A]) { return Data([0x0D, 0x0A]) }
        if line.last == 0x0A { return Data([0x0A]) }
        return Data()
    }
}
