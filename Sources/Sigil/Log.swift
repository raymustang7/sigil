import Foundation

/// Minimal append-only diagnostic logger. Writes to `~/Library/Logs/Sigil/sigil.log` (visible in
/// Console.app) so it can be inspected regardless of how the bundle was launched. The file lives
/// in the user's own Library and is created owner-only, so other accounts on the Mac can't read
/// it or plant a symlink in its place, as they could with a fixed path in /tmp.
enum Log {
    static let path: String = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Sigil", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        return dir.appendingPathComponent("sigil.log").path
    }()

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            FileManager.default.createFile(
                atPath: path, contents: data, attributes: [.posixPermissions: 0o600]
            )
        }
    }
}
