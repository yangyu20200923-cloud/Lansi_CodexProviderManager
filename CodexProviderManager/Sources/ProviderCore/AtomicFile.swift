import Foundation

public enum AtomicFile {
    public static func replace(_ url: URL, with data: Data) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        try data.write(to: temporary, options: .atomic)
        if let permissions {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }
}
