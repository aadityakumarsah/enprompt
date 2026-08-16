import Foundation

/// Appends diagnostics to ~/Library/Logs/enprompt.log so capture failures are
/// observable without the unified log.
enum DebugLogger {
    static let url = URL(fileURLWithPath: NSString("~/Library/Logs/enprompt.log").expandingTildeInPath)

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: url)
        }
    }
}