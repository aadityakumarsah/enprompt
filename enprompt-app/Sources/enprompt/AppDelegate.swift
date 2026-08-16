import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var monitor: KeyboardMonitor?
    private var trustTimer: Timer?
    private var statusItemController: StatusItemController?
    private var overlayController: EnhanceOverlayController?
    private var instanceLockFD: Int32 = -1

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hidden CLI mode: verify key detection + provider validation against
        // the real APIs, then exit. Used during development/testing.
        if CommandLine.arguments.contains("--self-test") {
            runSelfTest()
            return
        }

        // Single instance: launchd (Start at login) may race with a manual
        // launch. If another instance holds the lock, quit immediately. The
        // lock lives OUTSIDE the bundle - rebuilds replace the bundle and
        // would otherwise delete the lock file, allowing two instances.
        let lockDir = NSHomeDirectory() + "/Library/Application Support/enprompt"
        try? FileManager.default.createDirectory(atPath: lockDir, withIntermediateDirectories: true)
        let lockPath = lockDir + "/instance.lock"
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                DebugLogger.log("ANOTHER INSTANCE RUNNING — quitting")
                exit(0)
            }
            instanceLockFD = fd
        }

        // Always-on by default: register with launchd so enprompt starts at login
        // and keeps running (restart on crash). Never override an explicit
        // "Start at login = off" from Settings - the toggle stores its choice
        // in UserDefaults, so a disabled agent stays disabled across launches.
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "launchAtLoginEnabled") == nil || defaults.bool(forKey: "launchAtLoginEnabled") {
            LaunchAgentManager.install()
        }

        statusItemController = StatusItemController()
        statusItemController?.install()

        overlayController = EnhanceOverlayController()
        overlayController?.install()

        if !AXService.isTrusted {
            AXService.requestPermission()
        }
        // Ask for mic + speech up-front so no flow ever prompts mid-way.
        AppState.shared.requestPrivacyPermissions()
        startMonitor()

        // The event tap can only be created once Accessibility permission is
        // granted, which may happen after launch. Retry until it succeeds.
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                AppState.shared.refreshPermissions()
                if AppState.shared.isAccessibilityTrusted, self.monitor == nil {
                    self.startMonitor()
                }
            }
        }

        // First run: walk the user through the permissions once so everything
        // (text expansion, dictation, canvas) works without further prompts.
        if !AXService.isTrusted || !ScreenCapture.isAuthorized {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        trustTimer?.invalidate()
    }

    private func startMonitor() {
        let monitor = KeyboardMonitor()
        self.monitor = monitor

        // The event tap fires on the main run loop, so the main thread is
        // guaranteed here; assumeIsolated just tells the compiler that.
        monitor.onOptionDoubleTap = { gap in
            MainActor.assumeIsolated {
                DebugLogger.log("OPTION DOUBLE-TAP (gap=\(String(format: "%.2f", gap))s) — enhancing focused text")
                Task { await AppState.shared.enhanceFocusedText() }
            }
        }
        monitor.onOptionHoldStart = {
            MainActor.assumeIsolated {
                DebugLogger.log("OPTION HELD — starting dictation")
                Task { await AppState.shared.startDictation() }
            }
        }
        monitor.onOptionHoldEnd = {
            MainActor.assumeIsolated {
                DebugLogger.log("OPTION RELEASED — stopping dictation")
                AppState.shared.stopDictation()
            }
        }
        monitor.onUndoKey = {
            MainActor.assumeIsolated {
                AppState.shared.undoLastEnhancement()
            }
        }
        monitor.onOptionTripleTap = {
            MainActor.assumeIsolated {
                DebugLogger.log("OPTION TRIPLE-TAP — visual capture")
                AppState.shared.startVisualCapture()
            }
        }
        monitor.onEscapeKey = {
            MainActor.assumeIsolated {
                AppState.shared.handleVisualCaptureEscape()
            }
        }

        guard monitor.start() else {
            NSLog("enprompt: could not create event tap — Accessibility permission missing")
            DebugLogger.log("EVENT TAP FAILED — Accessibility permission missing")
            self.monitor = nil
            return
        }
        NSLog("enprompt: global keyboard monitor started")
        DebugLogger.log("EVENT TAP STARTED")
    }

    private func runSelfTest() {
        // Detached: the test Task must not be pinned to the main actor, or the
        // semaphore wait below would deadlock with the main run loop.
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await SelfTest.run()
            semaphore.signal()
        }
        semaphore.wait()
        exit(0)
    }
}