import Foundation

/// Minimal append-only diagnostic logger. Writes to a fixed path so it can be inspected
/// regardless of how the bundle was launched (via `open`, Finder, etc.).
enum Log {
    static let path = "/tmp/sigil.log"

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
