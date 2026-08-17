import AppKit
import Foundation

/// Metadata about a newer enprompt release found on GitHub.
struct UpdateInfo: Equatable {
    let version: String   // "1.9.2"
    let downloadURL: URL  // .dmg asset on the release
    let notes: String
}

/// Checks GitHub Releases for a newer enprompt build.
///
/// The app isn't notarized and has no Sparkle feed, so updates work the same
/// way as the landing site: download the new DMG and open it. The user keeps
/// their old copy until they drag the new one over - no Apple signing needed.
enum UpdateChecker {

    static let repo = "aadityakumarsah/enprompt"
    private static let latestURL =
        URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    /// e.g. "1.9.1" from the built app's Info.plist.
    static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Fetches the latest GitHub release. Returns nil when the running build
    /// is already current (or newer - e.g. a pre-release local build).
    static func check() async throws -> UpdateInfo? {
        var request = URLRequest(url: latestURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("enprompt-updater/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tag = json?["tag_name"] as? String,
              let body = json?["body"] as? String,
              let assets = json?["assets"] as? [[String: Any]],
              let download = assets.compactMap({ $0["browser_download_url"] as? String })
                  .first(where: { $0.hasSuffix(".dmg") }),
              let url = URL(string: download)
        else { return nil }

        let tagVersion = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let current = currentVersion,
              Self.isNewer(tagVersion, than: current)
        else { return nil }

        return UpdateInfo(version: tagVersion, downloadURL: url, notes: body)
    }

    /// Downloads the release DMG into ~/Downloads and opens it (Finder mounts
    /// it and offers the drag-to-Applications flow). Fallback when the running
    /// bundle can't be replaced in place.
    static func downloadAndOpen(_ info: UpdateInfo) async throws {
        let dest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("enprompt-\(info.version).dmg")
        let (data, _) = try await URLSession.shared.data(from: info.downloadURL)
        try data.write(to: dest, options: .atomic)
        NSWorkspace.shared.open(dest)
    }

    /// Fully automatic update: downloads the DMG, mounts it, swaps the new
    /// enprompt.app over the running bundle, and schedules a relaunch that
    /// survives this process terminating. Throws when the bundle can't be
    /// replaced - the caller falls back to downloadAndOpen.
    ///
    /// The copy is local (no quarantine xattr), so the replacement launches
    /// without a Gatekeeper prompt, and the signature carried by the DMG's
    /// bundle is preserved byte-for-byte.
    static func replaceRunningApp(with info: UpdateInfo) async throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        // Only possible where the .app can actually be replaced.
        guard fm.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            throw UpdateError.notWritable
        }

        let tmp = fm.temporaryDirectory
        let dmgURL = tmp.appendingPathComponent("enprompt-\(info.version).dmg")
        let (data, _) = try await URLSession.shared.data(from: info.downloadURL)
        try data.write(to: dmgURL, options: .atomic)

        let mountPoint = try mount(dmgURL)
        defer { detach(mountPoint) }

        let newApp = mountPoint.appendingPathComponent("enprompt.app")
        guard fm.fileExists(atPath: newApp.path) else { throw UpdateError.badDMG }

        // Swap: the running process keeps running from its loaded binary while
        // the bundle on disk is replaced.
        _ = try? fm.removeItem(at: appURL)
        try fm.copyItem(at: newApp, to: appURL)

        // Relaunch from a detached shell so it survives this app terminating.
        let script = "sleep 1; open \"\(appURL.path)\""
        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: "/bin/sh")
        sh.arguments = ["-c", script]
        try sh.run()
    }

    private enum UpdateError: LocalizedError {
        case notWritable
        case badDMG
        case mountFailed
        var errorDescription: String? {
            switch self {
            case .notWritable: "The app isn't in a writable location - use the DMG instead."
            case .badDMG: "The downloaded DMG didn't contain enprompt.app."
            case .mountFailed: "Couldn't mount the downloaded DMG."
            }
        }
    }

    /// Attaches the DMG read-only and returns its /Volumes mount point.
    private static func mount(_ dmgURL: URL) throws -> URL {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["attach", dmgURL.path, "-nobrowse", "-readonly"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        try proc.run()
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard let line = out.components(separatedBy: .newlines)
                .first(where: { $0.contains("/Volumes/") }),
              let path = line.split(separator: "\t").last?.trimmingCharacters(in: .whitespaces)
        else { throw UpdateError.mountFailed }
        return URL(fileURLWithPath: path)
    }

    private static func detach(_ mountPoint: URL) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        proc.arguments = ["detach", mountPoint.path]
        try? proc.run()
        proc.waitUntilExit()
    }

    /// "1.9.10" > "1.9.2", numeric per component.
    private static func isNewer(_ tag: String, than current: String) -> Bool {
        let a = tag.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}