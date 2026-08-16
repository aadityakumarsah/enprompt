import Foundation

/// Installs a LaunchAgent so enprompt starts automatically at login and stays
/// running (restarted on crash) until the user turns it off.
enum LaunchAgentManager {

    static let label = "com.enprompt.app"
    static let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/com.enprompt.app.plist"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func install() {
        guard !isInstalled, let executable = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable],
            "RunAtLoad": true,
            // Restart on crash, but respect a manual quit.
            "KeepAlive": ["SuccessfulExit": false],
        ]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
            _ = run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath])
            DebugLogger.log("LAUNCH AGENT installed at \(plistPath)")
        } catch {
            DebugLogger.log("LAUNCH AGENT install failed: \(error.localizedDescription)")
        }
    }

    static func uninstall() {
        _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())", plistPath])
        try? FileManager.default.removeItem(atPath: plistPath)
        DebugLogger.log("LAUNCH AGENT removed")
    }

    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        } catch {
            return -1
        }
    }
}