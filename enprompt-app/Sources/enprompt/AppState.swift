import AppKit
import AVFoundation
import Foundation
import ImageIO
import Speech

struct EnhanceStatus: Equatable {
    let isError: Bool
    let message: String
}

/// A friendly, actionable error: a short title, plain-language guidance on
/// what to do next, and an optional one-click fix that opens the right place.
struct EnhanceError: Equatable {
    enum Fix: Equatable {
        case accessibility
        case llm
        case systemPrompt
        case privacyPane
    }

    let title: String
    let guidance: String
    let fix: Fix?
}

enum EnhancePhase: Equatable {
    case idle
    case enhancing(Int)
    case listening(String)
    case success(String)
    case error(EnhanceError)
}

@MainActor
final class AppState: ObservableObject {

    static let shared = AppState()

    @Published var isAccessibilityTrusted = AXService.isTrusted
    @Published var screenRecordingGranted = ScreenCapture.isAuthorized
    @Published var microphoneGranted = false
    @Published var speechGranted = false
    @Published var launchAtLogin = LaunchAgentManager.isInstalled

    @Published var provider: LLMProvider = .anthropic
    @Published var model: String = LLMProvider.anthropic.defaultModel
    @Published var baseURL: String = LLMProvider.anthropic.defaultBaseURL
    @Published var apiKey: String = ""
    /// Model used for visual capture (⌥⌥⌥) when the user picked one in
    /// Settings; empty means "use the provider's default vision model".
    @Published var visionModel: String = ""
    @Published var systemPrompt: String = LLMClient.defaultSystemPrompt
    /// The setup form stays collapsed once an API key is saved; clicking the
    /// status indicator expands it again to change the key/provider.
    @Published var llmSetupExpanded = false

    @Published var isEnhancing = false
    @Published var enhancePhase: EnhancePhase = .idle
    @Published var testStatus: EnhanceStatus?

    /// Transient confirmation after saving a system prompt preset, e.g.
    /// "Saved — X.com (Twitter) reply is now the active prompt".
    @Published var promptSavedMessage: String? = nil

    /// Push-to-talk dictation: hold Option to speak, release to insert.
    @Published var isListening = false
    private let transcriber = SpeechTranscriber()
    private var dictationFinished = false
    private var dictationSession = 0

    /// The last successful enhancement, so Cmd+Z / Ctrl+Z can restore the
    /// original text (AX/paste write-backs are not undoable by the target app).
    private struct UndoRecord {
        let element: AXUIElement
        let appElement: AXUIElement?
        let appPID: pid_t
        let isTerminal: Bool
        let originalText: String
        let date: Date
    }
    private var lastUndo: UndoRecord?

    /// Visual capture: triple-tap ⌥ → draw on a canvas (pen/shapes/laser) →
    /// speak (live transcript) → Enter → a perfect prompt is generated from
    /// the annotated screenshot + voice, pasted, and saved to history.
    @Published var visualCaptureEnabled: Bool
    /// Recently generated visual prompts: copy or remove them from the popover.
    @Published var capturedPrompts: [String] = []
    private let canvas = CanvasController()
    private var visualCaptureDone = false
    private var visualCaptureFocus: AXService.FocusedInput?

    /// Estimated LLM tokens consumed (never billed - see LLMClient estimates).
    /// Session resets at launch; total persists so users can see lifetime use.
    @Published private(set) var sessionTokens = 0
    @Published private(set) var totalTokens: Int

    /// Models installed on the local Ollama server (via GET /api/tags), for
    /// the Settings model picker. Empty while loading / when Ollama is off.
    @Published var ollamaModels: [String] = []
    @Published var ollamaModelError: String?
    /// Non-nil while a model download is in progress (shown in Settings).
    @Published var ollamaPullStatus: String?

    /// A newer enprompt release exists on GitHub - shown as a banner in the
    /// popover with a one-click download (DMG + Finder, no notarization).
    @Published var updateInfo: UpdateInfo?
    @Published var isCheckingForUpdate = false
    @Published var isDownloadingUpdate = false

    private let defaults = UserDefaults.standard

    /// The last text selection seen anywhere (a tweet, an article...), so a
    /// selection made just before opening the popover can still be used even
    /// though the popover itself has focus by then. Refreshed every second
    /// while another app is frontmost.
    @Published private(set) var lastSelection: String? = nil
    private var lastSelectionDate = Date.distantPast
    private var selectionWatcher: Timer?

    /// The pre-rename default system prompt ("You are Treki…"): stored configs
    /// that still hold it are migrated to the new default on launch.
    static let legacyDefaultSystemPrompt = LLMClient.defaultSystemPrompt
        .replacingOccurrences(of: "You are enprompt,", with: "You are Treki,")

    init() {
        // Must be assigned before any other self use.
        visualCaptureEnabled = defaults.object(forKey: "visualCaptureEnabled") as? Bool ?? true
        capturedPrompts = defaults.stringArray(forKey: "capturedPrompts") ?? []
        totalTokens = defaults.integer(forKey: "tokenUsageTotal")
        if let raw = defaults.string(forKey: "provider"), let provider = LLMProvider(rawValue: raw) {
            self.provider = provider
        }
        // Migrate setups that pointed OpenAI-compatible at OpenRouter's API
        // to the dedicated OpenRouter provider so the UI stays truthful.
        let storedBaseURL = defaults.string(forKey: "baseURL")
        if self.provider == .openAI, storedBaseURL?.contains("openrouter.ai") == true {
            self.provider = .openRouter
        }
        if let stored = defaults.string(forKey: "model") {
            // Migrate the unreliable rotating free pool to a pinned model.
            model = (stored == "openrouter/free" || stored == "openrouter/auto")
                ? provider.defaultModel
                : stored
        } else {
            model = provider.defaultModel
        }
        baseURL = defaults.string(forKey: "baseURL") ?? provider.defaultBaseURL
        visionModel = defaults.string(forKey: "visionModel") ?? ""
        apiKey = KeychainStore.load() ?? ""
        // First launch under the new bundle id: carry the API key over from the
        // old com.treki.app keychain entry and drop the old entry.
        if apiKey.isEmpty, let legacy = KeychainStore.loadLegacy() {
            apiKey = legacy
            KeychainStore.save(legacy)
            KeychainStore.deleteLegacy()
            DebugLogger.log("KEYCHAIN: migrated API key from legacy service")
        }
        if let prompt = defaults.string(forKey: "systemPrompt"), !prompt.isEmpty {
            systemPrompt = prompt
        }
        // Renamed the assistant: swap the old default system prompt for the new.
        if systemPrompt == Self.legacyDefaultSystemPrompt {
            systemPrompt = LLMClient.defaultSystemPrompt
        }
        startSelectionWatcher()
    }

    /// Watches for text selections in the frontmost app so a selection made
    /// just before the popover opens is not lost when focus moves.
    private func startSelectionWatcher() {
        selectionWatcher?.invalidate()
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self,
                  !self.isEnhancing,
                  let front = NSWorkspace.shared.frontmostApplication,
                  front.processIdentifier != getpid() else { return }
            guard let selection = AXService.focusedSelection(), !selection.isEmpty else { return }
            self.lastSelection = selection
            self.lastSelectionDate = Date()
        }
        RunLoop.main.add(timer, forMode: .common)
        selectionWatcher = timer
    }

    /// Best-effort read of the selection for the Prepare-reply flow: the live
    /// AX selection, then the recently cached one (selection survives the
    /// popover stealing focus). The cached path is only used by Prepare
    /// reply - plain Enhance never touches it.
    private func bestSelectionText() -> String? {
        if let selection = AXService.focusedSelection(), !selection.isEmpty {
            return selection
        }
        if let cached = lastSelection, !cached.isEmpty,
           Date().timeIntervalSince(lastSelectionDate) < 60 {
            return cached
        }
        return nil
    }

    var config: LLMConfig {
        LLMConfig(provider: provider, model: model, apiKey: apiKey, baseURL: baseURL, visionModel: visionModel)
    }

    /// The provider inferred from the key currently in the field. nil when the
    /// key matches no known provider.
    var detectedProvider: LLMProvider? {
        LLMProvider.providerForAPIKey(apiKey)
    }

    // MARK: - Persistence

    func persistConfig() {
        defaults.set(provider.rawValue, forKey: "provider")
        defaults.set(model, forKey: "model")
        defaults.set(baseURL, forKey: "baseURL")
        defaults.set(visionModel, forKey: "visionModel")
        defaults.set(systemPrompt, forKey: "systemPrompt")
        if !apiKey.isEmpty {
            KeychainStore.save(apiKey)
        }
    }

    /// The name of the preset matching the current system prompt, nil when
    /// the prompt is custom.
    var activePresetName: String? {
        if systemPrompt == LLMClient.defaultSystemPrompt {
            return "Polished rewrite (default)"
        }
        for (name, prompt) in LLMClient.promptPresets where prompt == systemPrompt {
            return name
        }
        return nil
    }

    /// The reply presets offered by the Prepare-reply menu.
    static let replyPresetNames: [String] = LLMClient.promptPresets.keys
        .filter { $0.lowercased().contains("reply") }
        .sorted()

    /// True when a reply preset (X.com, Email, Founder) is the active prompt:
    /// only then does the popover show the Prepare-reply menu instead of the
    /// plain Enhance button.
    var isReplyPromptActive: Bool {
        guard let name = activePresetName else { return false }
        return Self.replyPresetNames.contains(name)
    }

    /// Turns any thrown error into a friendly, actionable EnhanceError.
    static func enhanceError(from error: Error) -> EnhanceError {
        guard let llm = error as? LLMError else {
            return EnhanceError(
                title: "Something went wrong",
                guidance: "Please try again. If it keeps happening, check the log at ~/Library/Logs/enprompt.log.",
                fix: nil
            )
        }
        switch llm {
        case .notConfigured:
            return EnhanceError(
                title: "No AI provider is set up yet",
                guidance: "Open Settings and paste your API key - or pick Ollama for a free local setup.",
                fix: .llm
            )
        case .unknownProvider:
            return EnhanceError(
                title: "We couldn't recognise that API key",
                guidance: "Keys start with sk-ant- (Claude), sk- (ChatGPT/Codex), sk-or-v1- (OpenRouter), AIza (Gemini) or ollama (local).",
                fix: .llm
            )
        case .http(let code, _):
            switch code {
            case 401, 403:
                return EnhanceError(
                    title: "Your API key was rejected",
                    guidance: "Open Settings and paste a valid key.",
                    fix: .llm
                )
            case 402, 429:
                return EnhanceError(
                    title: "Rate limit or credits reached",
                    guidance: "Wait a few minutes or check your plan, then try again.",
                    fix: nil
                )
            case 400:
                return EnhanceError(
                    title: "The AI provider rejected that request",
                    guidance: "This usually passes on a retry - please try again.",
                    fix: nil
                )
            case 404:
                return EnhanceError(
                    title: "That AI model wasn't found",
                    guidance: "Check the model name in Settings.",
                    fix: .llm
                )
            case 500...599:
                return EnhanceError(
                    title: "The AI provider is having issues right now",
                    guidance: "Please try again in a moment.",
                    fix: nil
                )
            default:
                return EnhanceError(
                    title: "Something went wrong talking to the AI",
                    guidance: "Please try again.",
                    fix: nil
                )
            }
        case .decoding:
            return EnhanceError(
                title: "The AI's response couldn't be read",
                guidance: "Please try again.",
                fix: nil
            )
        case .emptyResponse:
            return EnhanceError(
                title: "The AI returned an empty response",
                guidance: "Please try again - if it keeps happening, shorten the text.",
                fix: nil
            )
        }
    }

    /// Saves the system prompt and briefly confirms it, e.g.
    /// "Saved — X.com (Twitter) reply is now the active prompt".
    func saveSystemPrompt() {
        persistConfig()
        let name = activePresetName ?? "Custom"
        let message = "Saved — \(name) is now the active prompt"
        promptSavedMessage = message
        DebugLogger.log("SYSTEM PROMPT SAVED: \(name)")
        Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            await MainActor.run {
                if self.promptSavedMessage == message {
                    self.promptSavedMessage = nil
                }
            }
        }
    }

    /// Fetches the models installed on the local Ollama server so the Settings
    /// pickers can offer them. Safe to call anytime - errors just leave the
    /// list empty with a friendly message.
    func loadOllamaModels() async {
        guard provider == .ollama else { return }
        ollamaModels = []
        ollamaModelError = nil
        do {
            let models = try await LLMClient.fetchOllamaModels(baseURL: baseURL)
            ollamaModels = models
            // If the user never picked a vision model, default to the first
            // vision-capable one - sending a screenshot to a text-only model
            // (e.g. llama3.2) is exactly how "AI provider rejected the
            // request" errors happen.
            if visionModel.isEmpty,
               let firstVision = models.first(where: LLMClient.isVisionModel) {
                visionModel = firstVision
                persistConfig()
                DebugLogger.log("OLLAMA: auto-picked vision model \(firstVision)")
            }
            DebugLogger.log("OLLAMA: found \(ollamaModels.count) local models: \(ollamaModels.joined(separator: ", "))")
        } catch {
            ollamaModelError = (error as? LLMError)?.userFacingMessage ?? "Couldn't reach the Ollama server - is it running?"
            DebugLogger.log("OLLAMA: model list failed: \(error.localizedDescription)")
        }
    }

    /// Downloads a model through the local Ollama server so a brand-new user
    /// needs zero terminal commands to get going. Shows progress in Settings.
    func pullOllamaModel(_ name: String) async {
        guard ollamaPullStatus == nil else { return }
        ollamaPullStatus = "Downloading \(name) - this can take a few minutes…"
        ollamaModelError = nil
        DebugLogger.log("OLLAMA: pulling \(name)")
        do {
            try await LLMClient.pullOllamaModel(name, baseURL: baseURL)
            ollamaPullStatus = nil
            await loadOllamaModels()
            ollamaModelError = "\(name) is installed and ready to use"
            DebugLogger.log("OLLAMA: pulled \(name)")
        } catch {
            ollamaPullStatus = nil
            ollamaModelError = "Download failed - check your internet connection and try again"
            DebugLogger.log("OLLAMA: pull \(name) failed: \(error.localizedDescription)")
        }
    }

    /// Opens the free Ollama download page - the first step for a new user
    /// who has never installed anything AI-related.
    func openOllamaDownload() {
        if let url = URL(string: "https://ollama.com/download") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Launches the Ollama menu-bar app (macOS apps can't trust PATH, so the
    /// app path is used directly).
    func startOllamaApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Ollama.app"))
    }

    /// Opens the enprompt "run locally" guide - installation commands, model
    /// pulls, disk space, and benchmarks for anyone without an API key.
    func openLocalSetupPage() {
        if let url = URL(string: "https://enprompt.pages.dev/run-locally/") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Opens the same local-setup guide from any model's ? button. The guide
    /// is a single page (no per-model sections), so the model name is not
    /// used in the URL - kept as a parameter in case the page gains anchors.
    func openModelGuide(_ model: String) {
        if let url = URL(string: "https://enprompt.pages.dev/run-locally/") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Updates

    /// Checks GitHub for a newer release. `force` bypasses the hourly auto-check
    /// throttle; auto-checks run at launch, every 6 hours, and on popover open.
    func checkForUpdates(force: Bool = false) async {
        guard !isCheckingForUpdate, updateInfo == nil else { return }
        if !force, Date().timeIntervalSince(lastUpdateCheck) < 3600 { return }
        isCheckingForUpdate = true
        defer { isCheckingForUpdate = false }
        do {
            if let info = try await UpdateChecker.check() {
                updateInfo = info
            }
            lastUpdateCheck = Date()
        } catch {
            DebugLogger.log("UPDATE: check failed - \(error.localizedDescription)")
        }
    }

    /// Fully automatic update: swaps the new app in place and relaunches. If
    /// the bundle can't be replaced (read-only location), falls back to
    /// downloading the DMG and opening it in Finder. The banner stays until
    /// the user dismisses it or the update succeeds.
    func downloadAndInstallUpdate() {
        guard let info = updateInfo, !isDownloadingUpdate else { return }
        isDownloadingUpdate = true
        Task {
            do {
                try await UpdateChecker.replaceRunningApp(with: info)
                updateInfo = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NSApp.terminate(nil)
                }
            } catch {
                DebugLogger.log("UPDATE: in-place install failed - \(error.localizedDescription); falling back to DMG")
                do {
                    try await UpdateChecker.downloadAndOpen(info)
                    updateInfo = nil
                } catch {
                    DebugLogger.log("UPDATE: download failed - \(error.localizedDescription)")
                }
            }
            isDownloadingUpdate = false
        }
    }

    func dismissUpdate() {
        updateInfo = nil
    }

    private var lastUpdateCheck: Date {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }

    func applyProviderDefaults() {
        model = provider.defaultModel
        baseURL = provider.defaultBaseURL
        persistConfig()
    }

    // MARK: - Captures

    func refreshTrust() {
        refreshPermissions()
    }

    /// Polled every second: keeps every permission status up to date and
    /// relaunches the app the moment Screen Recording is granted (macOS only
    /// honors that grant after a process restart).
    func refreshPermissions() {
        let trusted = AXService.isTrusted
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }
        let screenRecording = ScreenCapture.isAuthorized
        if screenRecording != screenRecordingGranted {
            screenRecordingGranted = screenRecording
            if screenRecording {
                relaunchAfterPermissionGrant()
            }
        }
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        speechGranted = SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    /// Asks for mic + speech up-front at launch so dictation and the canvas
    /// never have to prompt in the middle of a flow. Also triggers the
    /// Screen Recording prompt: using ScreenCaptureKit makes macOS show the
    /// one-click Allow dialog automatically - no System Settings needed.
    func requestPrivacyPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { _ in }
        }
        if !ScreenCapture.isAuthorized {
            Task { await ScreenCapture.requestPermission() }
        }
    }

    /// Screen Recording only takes effect after a restart, so relaunch
    /// automatically: through launchd when the launch agent is installed,
    /// otherwise via `open`. Also usable as a manual "Restart enprompt now".
    func relaunchAfterPermissionGrant() {
        DebugLogger.log("SCREEN RECORDING GRANTED — relaunching automatically")
        let script: String
        if LaunchAgentManager.isInstalled {
            script = "sleep 1; launchctl kickstart -k gui/\(getuid())/com.enprompt.app"
        } else {
            script = "sleep 1; open \"\(Bundle.main.bundlePath)\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        // Without launchd, make sure the old process does not linger.
        if !LaunchAgentManager.isInstalled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                exit(1)
            }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = enabled
        // Persist the choice: on launch the app only reinstalls the agent
        // when this flag isn't explicitly false (see AppDelegate).
        defaults.set(enabled, forKey: "launchAtLoginEnabled")
        if enabled {
            LaunchAgentManager.install()
        } else {
            LaunchAgentManager.uninstall()
        }
    }

    // MARK: - Token usage

    /// Adds an estimated token count for one LLM exchange (prompt + completion,
    /// plus optional vision image pixels) to the session and lifetime counters.
    func recordUsage(promptText: String, completionText: String, imagePixels: Int? = nil) {
        let used = LLMClient.estimateTokens(promptText)
            + LLMClient.estimateTokens(completionText)
            + (imagePixels.map { LLMClient.estimateImageTokens(pixels: $0) } ?? 0)
        sessionTokens += used
        totalTokens += used
        defaults.set(totalTokens, forKey: "tokenUsageTotal")
    }

    func resetTokenUsage() {
        sessionTokens = 0
        totalTokens = 0
        defaults.set(0, forKey: "tokenUsageTotal")
    }

    // MARK: - Enhance

    /// Reads the focused text field, asks the LLM for an expanded version,
    /// and writes it back. Falls back to the clipboard if write-back fails.
    func enhanceFocusedText() async {
        guard !isEnhancing else {
            DebugLogger.log("ENHANCE SKIPPED: already enhancing")
            return
        }
        guard AXService.isTrusted else {
            enhancePhase = .error(EnhanceError(
                title: "Accessibility permission is off",
                guidance: "enprompt needs Accessibility to read what you select. Open Settings → Setup and grant it.",
                fix: .accessibility
            ))
            DebugLogger.log("ENHANCE SKIPPED: not trusted")
            return
        }
        // The element is read a few times with a short delay: the window the
        // user is typing in may still be settling focus right after the click.
        var input: AXService.FocusedInput?
        for attempt in 0..<3 {
            input = AXService.focusedTextInput()
            if input != nil { break }
            DebugLogger.log("ENHANCE read attempt \(attempt + 1): no focused editable input yet")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        guard let input else {
            // 1. A live selection anywhere (read-only text: tweets, posts).
            if let selection = AXService.focusedSelection(), !selection.isEmpty {
                await enhanceToClipboard(selection)
                return
            }
            // 2. Web-content apps (Cursor, VS Code and other Electron apps)
            //    hide their focused input from the AX focus attributes. When
            //    the user is inside web content, select all + copy via the
            //    keyboard and enhance that - the result is pasted back.
            if AXService.webContentElement() != nil {
                let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let copied = KeyboardInputService.copyCurrentText(in: pid)
                if !copied.isEmpty {
                    await enhanceAndPasteInPlace(copied, appPID: pid)
                    return
                }
                DebugLogger.log("ENHANCE keyboard fallback: copied text was empty")
            }
            enhancePhase = .error(EnhanceError(
                title: "No text found",
                guidance: "Click into the text field you want to enhance (or select the text first), then try again.",
                fix: nil
            ))
            DebugLogger.log("ENHANCE SKIPPED: no focused editable input after retries — \(AXService.focusedElementDebugInfo())")
            return
        }
        let bundleID = input.appPID > 0 ? NSRunningApplication(processIdentifier: input.appPID)?.bundleIdentifier : nil
        let isTerminal = AXService.isTerminalApp(bundleID)

        // If the user selected specific text, enhance ONLY that selection.
        // Otherwise enhance the whole input.
        let selection = AXService.selectedText(of: input.element)

        var textToEnhance: String
        var selectionLocation: Int?
        var selectionLength: Int?
        var fullInput: String
        var terminalHasPrompt = true
        if isTerminal {
            let stripped = input.text.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
            let extracted = Self.extractTerminalInput(from: stripped)
            textToEnhance = extracted.text
            // Editor statuslines are filtered out above; a missing prompt
            // marker just means write-back happens via the clipboard instead
            // of in-place editing - never destructive.
            terminalHasPrompt = extracted.hasPrompt
            if !terminalHasPrompt {
                DebugLogger.log("ENHANCE terminal: no shell prompt marker — clipboard write-back only")
            }
            // Safety net: never send UI chrome to the LLM or write it back.
            if textToEnhance.isEmpty || textToEnhance.contains("ctrl+p") || textToEnhance.contains("OpenCode") || textToEnhance.contains("•") || textToEnhance.contains("·") {
                DebugLogger.log("ENHANCE SKIPPED: terminal input line looks like UI chrome")
                enhancePhase = .error(EnhanceError(
                    title: "No input text found in the terminal prompt",
                    guidance: "Type a command first, then double-tap ⌥ - or press ⌘C after selecting and try again.",
                    fix: nil
                ))
                return
            }
            // A selection is used only when it is part of the input line.
            if let selection, !selection.text.isEmpty {
                let range = (textToEnhance as NSString).range(of: selection.text)
                if range.length > 0 {
                    selectionLocation = range.location
                    selectionLength = range.length
                }
            }
            fullInput = textToEnhance
            if selectionLocation != nil, selectionLength != nil {
                textToEnhance = (textToEnhance as NSString).substring(with: NSRange(location: selectionLocation!, length: selectionLength!))
            }
        } else {
            fullInput = input.text
            textToEnhance = input.text
            // Any non-empty selection inside the focused field is enhanced.
            if let selection, !selection.text.isEmpty {
                selectionLocation = selection.location
                selectionLength = selection.length
                textToEnhance = selection.text
            }
        }

        if selectionLocation != nil {
            DebugLogger.log("ENHANCE using selection (\(selectionLength ?? 0) chars): \(textToEnhance.prefix(120))")
        }

        guard !textToEnhance.isEmpty else {
            enhancePhase = .error(EnhanceError(
                title: "No input text found",
                guidance: "Type something first\(isTerminal ? " in the terminal prompt" : ""), then try again.",
                fix: nil
            ))
            DebugLogger.log("ENHANCE SKIPPED: empty text")
            return
        }

        isEnhancing = true
        enhancePhase = .enhancing(0)
        NSSound(named: "Tink")?.play()
        defer { isEnhancing = false }

        let startedAt = Date()
        do {
            DebugLogger.log("ENHANCING \(textToEnhance.count) chars (\(isTerminal ? "terminal" : "AX input")) via \(config.provider.rawValue)/\(config.model)")
            if isTerminal {
                DebugLogger.log("TERMINAL input line: \(textToEnhance.replacingOccurrences(of: "\n", with: "\\n").prefix(200))")
            }
            let enhanced = try await LLMClient.enhance(
                textToEnhance,
                config: config,
                systemPrompt: systemPrompt
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.enhancePhase = .enhancing(progress)
                }
            }
            guard !enhanced.isEmpty else { throw LLMError.emptyResponse }
            recordUsage(promptText: systemPrompt + "\n" + textToEnhance, completionText: enhanced)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))

            if isTerminal {
                // Terminal TUIs: caret to end (Ctrl+E), delete the whole old
                // input line (backspace), paste the new line. If only a
                // selection was enhanced, the new line keeps the untouched
                // text around the selection.
                let newLine: String
                if let loc = selectionLocation, let len = selectionLength,
                   (fullInput as NSString).length >= loc + len,
                   (fullInput as NSString).substring(with: NSRange(location: loc, length: len)) == textToEnhance {
                    newLine = (fullInput as NSString).replacingCharacters(
                        in: NSRange(location: loc, length: len),
                        with: enhanced
                    )
                } else {
                    newLine = enhanced
                }
                if terminalHasPrompt {
                    KeyboardInputService.replaceTerminalInput(
                        newLine,
                        deletingChars: fullInput.count,
                        in: input.appPID
                    )
                    lastUndo = UndoRecord(
                        element: input.element,
                        appElement: input.appElement,
                        appPID: input.appPID,
                        isTerminal: true,
                        originalText: fullInput,
                        date: Date()
                    )
                    enhancePhase = .success("Replaced terminal input: \(textToEnhance.count) → \(enhanced.count) chars (\(elapsed)s)")
                    DebugLogger.log("ENHANCED terminal input \(textToEnhance.count) -> \(enhanced.count) chars in \(elapsed)s (Ctrl+E, backspace x\(fullInput.count), paste)")
                } else {
                    // No shell prompt on the line (custom prompt shape or a
                    // program that hides it): never edit in place - paste.
                    KeyboardInputService.pasteReplacingCurrentText(newLine, in: input.appPID)
                    enhancePhase = .success("Copied to clipboard: \(textToEnhance.count) → \(enhanced.count) chars (\(elapsed)s) - paste it after your prompt")
                    DebugLogger.log("ENHANCED terminal input \(textToEnhance.count) -> \(enhanced.count) chars in \(elapsed)s (clipboard - no shell prompt)")
                }
                NSSound(named: "Glass")?.play()
            } else {
                // Try the accessibility write, then verify it actually applied.
                // If a selection was enhanced, splice into the field's current
                // value at the selection range instead of replacing it all.
                let current = AXService.value(of: input.element) ?? fullInput
                let target: String
                if let loc = selectionLocation, let len = selectionLength,
                   (current as NSString).length >= loc + len,
                   (current as NSString).substring(with: NSRange(location: loc, length: len)) == textToEnhance {
                    target = (current as NSString).replacingCharacters(
                        in: NSRange(location: loc, length: len),
                        with: enhanced
                    )
                } else {
                    target = enhanced
                }
                let replaced = AXService.replaceText(target, in: input.element)
                    && AXService.value(of: input.element) == target

            if replaced {
                lastUndo = UndoRecord(
                    element: input.element,
                    appElement: input.appElement,
                    appPID: input.appPID,
                    isTerminal: false,
                    originalText: fullInput,
                    date: Date()
                )
                enhancePhase = .success("Expanded \(textToEnhance.count) → \(enhanced.count) chars (\(elapsed)s)")
                NSSound(named: "Glass")?.play()
                DebugLogger.log("ENHANCED \(textToEnhance.count) -> \(enhanced.count) chars in \(elapsed)s (AX write-back verified)")
            } else {
                // AX write-back failed or silently did nothing: simulate
                // Command-A + Command-V, which works in every app.
                AXService.focus(input.element, in: input.appElement)
                var appPID: pid_t = 0
                AXUIElementGetPid(input.element, &appPID)
                KeyboardInputService.pasteReplacingCurrentText(enhanced, in: appPID == 0 ? nil : appPID)
                lastUndo = UndoRecord(
                    element: input.element,
                    appElement: input.appElement,
                    appPID: input.appPID,
                    isTerminal: false,
                    originalText: fullInput,
                    date: Date()
                )
                enhancePhase = .success("Expanded + pasted \(enhanced.count) chars (\(elapsed)s)")
                NSSound(named: "Glass")?.play()
                DebugLogger.log("ENHANCED \(textToEnhance.count) -> \(enhanced.count) chars in \(elapsed)s (keyboard paste fallback)")
            }
            }
        } catch {
            enhancePhase = .error(Self.enhanceError(from: error))
            NSSound(named: "Sosumi")?.play()
            DebugLogger.log("ENHANCE FAILED: \(error.localizedDescription)")
        }
    }

    /// Enhances arbitrary selected text (read-only selections included) and
    /// writes the result to the clipboard. Used when no editable field is
    /// focused and by the Prepare-reply flow.
    private func enhanceToClipboard(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            enhancePhase = .error(EnhanceError(
                title: "No input text found",
                guidance: "Select or type the text you want to work with, then try again.",
                fix: nil
            ))
            return
        }
        isEnhancing = true
        enhancePhase = .enhancing(0)
        NSSound(named: "Tink")?.play()
        defer { isEnhancing = false }

        let startedAt = Date()
        do {
            DebugLogger.log("ENHANCING \(trimmed.count) chars (selection -> clipboard) via \(config.provider.rawValue)/\(config.model)")
            let enhanced = try await LLMClient.enhance(
                trimmed,
                config: config,
                systemPrompt: systemPrompt
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.enhancePhase = .enhancing(progress)
                }
            }
            guard !enhanced.isEmpty else { throw LLMError.emptyResponse }
            recordUsage(promptText: systemPrompt + "\n" + trimmed, completionText: enhanced)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(enhanced, forType: .string)
            enhancePhase = .success("\(trimmed.count) → \(enhanced.count) chars — copied to clipboard (\(elapsed)s), press ⌘V to paste")
            NSSound(named: "Glass")?.play()
            DebugLogger.log("ENHANCED \(trimmed.count) -> \(enhanced.count) chars to clipboard in \(elapsed)s")
        } catch {
            enhancePhase = .error(Self.enhanceError(from: error))
            NSSound(named: "Sosumi")?.play()
            DebugLogger.log("ENHANCE FAILED: \(error.localizedDescription)")
        }
    }

    /// Keyboard-fallback path for Electron apps (Cursor, VS Code): enhances
    /// text that was read via Command-A + Command-C and pastes the result
    /// back in place with Command-A + Command-V.
    private func enhanceAndPasteInPlace(_ text: String, appPID: pid_t?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            enhancePhase = .error(EnhanceError(
                title: "No input text found",
                guidance: "Type something into the field first, then try again.",
                fix: nil
            ))
            return
        }
        isEnhancing = true
        enhancePhase = .enhancing(0)
        NSSound(named: "Tink")?.play()
        defer { isEnhancing = false }

        let startedAt = Date()
        do {
            DebugLogger.log("ENHANCING \(trimmed.count) chars (keyboard fallback) via \(config.provider.rawValue)/\(config.model)")
            let enhanced = try await LLMClient.enhance(
                trimmed,
                config: config,
                systemPrompt: systemPrompt
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.enhancePhase = .enhancing(progress)
                }
            }
            guard !enhanced.isEmpty else { throw LLMError.emptyResponse }
            recordUsage(promptText: systemPrompt + "\n" + trimmed, completionText: enhanced)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))

            KeyboardInputService.pasteReplacingCurrentText(enhanced, in: appPID)
            enhancePhase = .success("Expanded \(trimmed.count) → \(enhanced.count) chars (\(elapsed)s)")
            NSSound(named: "Glass")?.play()
            DebugLogger.log("ENHANCED \(trimmed.count) -> \(enhanced.count) chars in \(elapsed)s (keyboard fallback, pasted in place)")
        } catch {
            enhancePhase = .error(Self.enhanceError(from: error))
            NSSound(named: "Sosumi")?.play()
            DebugLogger.log("ENHANCE FAILED: \(error.localizedDescription)")
        }
    }

    /// Prepares a reply to the currently selected text using the chosen reply
    /// preset as the system prompt, then copies the reply to the clipboard.
    /// Works on read-only selections (a tweet/post), no editable field needed.
    func prepareReply(preset: String?) async {
        guard !isEnhancing else {
            DebugLogger.log("REPLY SKIPPED: already enhancing")
            return
        }
        let systemPromptForReply: String
        if let preset {
            guard let prompt = LLMClient.promptPresets[preset] else {
                enhancePhase = .error(EnhanceError(
                    title: "That reply style isn't available anymore",
                    guidance: "Pick another style from the menu, or choose Custom prompt.",
                    fix: nil
                ))
                return
            }
            systemPromptForReply = prompt
        } else {
            systemPromptForReply = systemPrompt
        }
        guard !systemPromptForReply.isEmpty else {
            enhancePhase = .error(EnhanceError(
                title: "No reply style is set",
                guidance: "Open Settings → System Prompt, pick a reply preset (X.com, Email or Founder) and press Save.",
                fix: .systemPrompt
            ))
            return
        }

        // 1. The selection anywhere (editable or read-only), live or cached.
        var source = bestSelectionText()
        if source == nil || source!.isEmpty {
            // 2. Fall back to the focused editable field's text.
            source = AXService.focusedTextInput()?.text
        }
        if source == nil || source!.isEmpty {
            // 3. Last resort: whatever the user copied to the clipboard.
            source = NSPasteboard.general.string(forType: .string)
            if let s = source, !s.isEmpty {
                DebugLogger.log("REPLY using clipboard text (\(s.count) chars)")
            }
        }
        guard let text = source?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            enhancePhase = .error(EnhanceError(
                title: "No text to reply to",
                guidance: "Select the post text first (or copy it with ⌘C), then press Prepare reply again.",
                fix: nil
            ))
            DebugLogger.log("REPLY SKIPPED: no selection — \(AXService.focusedElementDebugInfo())")
            return
        }

        DebugLogger.log("REPLY preparing \(text.count) chars with preset '\(preset ?? "custom")'")
        await enhanceToClipboard(text, systemPromptOverride: systemPromptForReply)
    }

    private func enhanceToClipboard(_ text: String, systemPromptOverride: String) async {
        isEnhancing = true
        enhancePhase = .enhancing(0)
        NSSound(named: "Tink")?.play()
        defer { isEnhancing = false }

        let startedAt = Date()
        do {
            DebugLogger.log("ENHANCING \(text.count) chars (reply -> clipboard) via \(config.provider.rawValue)/\(config.model)")
            let enhanced = try await LLMClient.enhance(
                text,
                config: config,
                systemPrompt: systemPromptOverride
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.enhancePhase = .enhancing(progress)
                }
            }
            guard !enhanced.isEmpty else { throw LLMError.emptyResponse }
            recordUsage(promptText: systemPromptOverride + "\n" + text, completionText: enhanced)
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(startedAt))

            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(enhanced, forType: .string)
            enhancePhase = .success("Reply ready — copied to clipboard (\(elapsed)s), press ⌘V in the post box")
            NSSound(named: "Glass")?.play()
            DebugLogger.log("REPLY READY: \(text.count) -> \(enhanced.count) chars on clipboard in \(elapsed)s")
        } catch {
            enhancePhase = .error(Self.enhanceError(from: error))
            NSSound(named: "Sosumi")?.play()
            DebugLogger.log("REPLY FAILED: \(error.localizedDescription)")
        }
    }

    /// Sends a tiny probe through the provider detected from the CURRENT key
    /// in the field (not the stored one) to verify the key is valid.
    func testLLM() async {
        guard !apiKey.isEmpty else {
            testStatus = EnhanceStatus(isError: true, message: "Paste an API key first")
            return
        }
        guard let provider = detectedProvider else {
            testStatus = EnhanceStatus(isError: true, message: LLMError.unknownProvider.errorDescription ?? "Unknown provider")
            return
        }
        // Local Ollama: no key exists - the test is "can we reach the server
        // and does it have models?" (model names vary per machine, so probing
        // a hardcoded model would fail for people who pulled different ones).
        if provider == .ollama {
            testStatus = EnhanceStatus(isError: false, message: "Testing Ollama (local)…")
            do {
                let models = try await LLMClient.fetchOllamaModels(baseURL: baseURL)
                ollamaModels = models
                let visionCount = models.filter(LLMClient.isVisionModel).count
                testStatus = EnhanceStatus(
                    isError: false,
                    message: "Ollama connected - \(models.count) models installed (\(visionCount) vision-capable)"
                )
                DebugLogger.log("LLM TEST OK (ollama): \(models.joined(separator: ", "))")
            } catch {
                testStatus = EnhanceStatus(isError: true, message: "Couldn't reach Ollama at \(baseURL) - is the Ollama app running?")
                DebugLogger.log("LLM TEST FAILED (ollama): \(error.localizedDescription)")
            }
            return
        }
        testStatus = EnhanceStatus(isError: false, message: "Testing \(provider.displayName)…")
        let probe = LLMConfig(provider: provider, model: provider.defaultModel, apiKey: apiKey, baseURL: provider.defaultBaseURL)
        do {
            try await LLMClient.validate(config: probe)
            testStatus = EnhanceStatus(isError: false, message: "Key is valid - \(provider.displayName) connected")
            DebugLogger.log("LLM TEST OK (\(provider.rawValue))")
        } catch {
            testStatus = EnhanceStatus(isError: true, message: (error as? LLMError)?.userFacingMessage ?? "Couldn't reach the provider. Please try again.")
            DebugLogger.log("LLM TEST FAILED: \(error.localizedDescription)")
        }
    }

    /// Saves the typed API key ONLY after the provider is detected and the key
    /// validates against the real API. Returns true when saved.
    func saveAPIKey(_ key: String) async -> Bool {
        apiKey = key
        guard let provider = detectedProvider else {
            testStatus = EnhanceStatus(isError: true, message: LLMError.unknownProvider.errorDescription ?? "Unknown provider")
            return false
        }
        // Local Ollama: no key to check - just confirm the server answers and
        // remember the models it has.
        if provider == .ollama {
            // Coming from another provider: never validate against the old
            // provider's server URL.
            if self.provider != .ollama {
                baseURL = LLMProvider.ollama.defaultBaseURL
            }
            do {
                let models = try await LLMClient.fetchOllamaModels(baseURL: baseURL)
                ollamaModels = models
            } catch {
                testStatus = EnhanceStatus(isError: true, message: "Couldn't reach Ollama at \(baseURL) - is the Ollama app running?")
                DebugLogger.log("SAVE LLM REJECTED (ollama): \(error.localizedDescription)")
                return false
            }
            self.provider = provider
            persistConfig()
            llmSetupExpanded = false
            testStatus = nil
            DebugLogger.log("LLM SAVED: \(provider.displayName) (\(model), vision: \(visionModel.isEmpty ? "default" : visionModel))")
            return true
        }
        let probe = LLMConfig(provider: provider, model: provider.defaultModel, apiKey: key, baseURL: provider.defaultBaseURL)
        do {
            try await LLMClient.validate(config: probe)
        } catch {
            testStatus = EnhanceStatus(isError: true, message: (error as? LLMError)?.userFacingMessage ?? "Your key was rejected. Please try again.")
            DebugLogger.log("SAVE LLM REJECTED: \(error.localizedDescription)")
            return false
        }
        // Re-applying defaults only when the provider changed: a re-save of
        // the same provider must keep the model the user picked (e.g. a
        // locally installed Ollama vision model).
        let providerChanged = self.provider != provider
        self.provider = provider
        if providerChanged {
            model = provider.defaultModel
            baseURL = provider.defaultBaseURL
            if provider != .ollama { visionModel = "" }
        }
        persistConfig()
        llmSetupExpanded = false
        testStatus = nil
        DebugLogger.log("LLM SAVED: \(provider.displayName) (\(model))")
        return true
    }

    /// Restores the text as it was before the last enhancement. Called when
    /// the user presses Cmd+Z / Ctrl+Z. Returns true when the key should be
    /// swallowed (an enhancement was actually undone); false lets the key pass
    /// through to the focused app as a normal undo.
    func undoLastEnhancement() -> Bool {
        guard let undo = lastUndo else { return false }
        lastUndo = nil
        guard Date().timeIntervalSince(undo.date) < 30 else { return false }

        // Only restore when the user is still in the same field we enhanced.
        guard let focused = AXService.focusedTextInput(),
              CFEqual(focused.element, undo.element) else {
            DebugLogger.log("UNDO SKIPPED: focused field changed")
            return false
        }

        if undo.isTerminal {
            let stripped = focused.text.replacingOccurrences(
                of: "\u{1B}\\[[0-9;]*[A-Za-z]",
                with: "",
                options: .regularExpression
            )
            let currentLine = Self.extractTerminalInput(from: stripped).text
            KeyboardInputService.replaceTerminalInput(
                undo.originalText,
                deletingChars: currentLine.count,
                in: undo.appPID
            )
        } else {
            let restored = AXService.replaceText(undo.originalText, in: undo.element)
                && AXService.value(of: undo.element) == undo.originalText
            if !restored {
                AXService.focus(undo.element, in: undo.appElement)
                KeyboardInputService.pasteReplacingCurrentText(
                    undo.originalText,
                    in: undo.appPID > 0 ? undo.appPID : nil
                )
            }
        }
        enhancePhase = .success("Restored original text")
        NSSound(named: "Glass")?.play()
        DebugLogger.log("UNDO: restored \(undo.originalText.count) chars (was \(focused.text.count))")
        return true
    }

    // MARK: - Terminal input extraction

    /// Scans the terminal screen text (ANSI-stripped) from the bottom and
    /// returns the current input line:
    /// 1. A line starting with a prompt marker (❯ > ➜ → λ › $ %) is a
    ///    shell/claude-code/codex input - take the text after it.
    /// 2. Lines that look like TUI chrome (opencode status bars contain
    ///    "·"/"•"/"ctrl+p"/"OpenCode", borders and progress bars start with
    ///    ┃│╹▀⬝■▣) are skipped.
    /// 3. The first remaining line is the input.
    /// Extracts the user's current input line from a terminal screen dump.
    /// `hasPrompt` is false when no shell prompt marker was found (e.g. the
    /// bottom line is an editor statusline) - callers must not write back
    /// destructively in that case.
    static func extractTerminalInput(from stripped: String) -> (text: String, hasPrompt: Bool) {
        let promptMarkers = ["❯", ">", "➜", "→", "λ", "›", "$", "%"]
        let lines = stripped.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for line in lines.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let leading = trimmed.drop(while: { $0 == " " || $0 == "\t" })

            if let marker = promptMarkers.first(where: { leading.hasPrefix($0) }) {
                let text = String(leading.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return (text, true) }
                continue
            }
            // Custom prompts ("user@mb ~ % ls"): the prompt marker ends the
            // prompt. Use the LAST marker that follows whitespace - never one
            // embedded inside the command ("echo 100%").
            var markerStart: String.Index?
            var scan = leading.startIndex
            while scan < leading.endIndex {
                let ch = leading[scan]
                if promptMarkers.contains(String(ch)) {
                    let precededBySpace = scan == leading.startIndex
                        || leading[leading.index(before: scan)] == " "
                    if precededBySpace { markerStart = scan }
                }
                scan = leading.index(after: scan)
            }
            if let markerStart {
                let text = String(leading[leading.index(after: markerStart)...]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { return (text, true) }
            }
            if isTerminalChrome(trimmed) { continue }
            // No prompt marker: never treat editor statuslines (vim shows
            // "path:file line,col" or "file 203L, 4600C") as input.
            if isEditorStatusLine(trimmed) { continue }
            return (trimmed, false)
        }
        return ("", false)
    }

    /// True for vim/TUI statusline shapes: a path:file plus a line/col number,
    /// or a file name with a length/position counter.
    private static func isEditorStatusLine(_ line: String) -> Bool {
        if line.range(of: #"\s+\d+[.,]\d+\s*$"#, options: .regularExpression) != nil { return true }
        if line.range(of: #":\d+[.,]\d+"#, options: .regularExpression) != nil { return true }
        if line.range(of: #"\d+L, \d+C"#, options: .regularExpression) != nil { return true }
        let modeWords = ["All", "Insert", "Normal", "Visual", "Replace", "Command-line", "Recording", "recording", "Terminal-Focus", "Terminal"]
        if modeWords.contains(where: { line.contains($0) }) { return true }
        return false
    }

    private static let terminalChromeParts = ["·", "•", "ctrl+p", "OpenCode", "esc ", "commands", "OpenCode Zen"]

    /// True when a terminal screen line is TUI chrome (status bars, headers,
    /// borders, progress bars) rather than user input.
    private static func isTerminalChrome(_ line: String) -> Bool {
        if terminalChromeParts.contains(where: { line.contains($0) }) { return true }
        let borderPrefixes = ["┃", "│", "╹", "▀", "⬝", "■", "▣", "─", "╱", "╲"]
        let leading = line.drop(while: { $0 == " " || $0 == "\t" })
        if let first = leading.first, borderPrefixes.contains(String(first)) { return true }
        if line.range(of: #"\d+(\.\d+)?[KMG]? \("#, options: .regularExpression) != nil { return true }
        return false
    }

    // MARK: - Dictation (hold Option to speak)

    func startDictation() async {
        guard !isListening, !isEnhancing else { return }
        let (mic, speech) = await SpeechTranscriber.requestPermissions()
        guard mic else {
            enhancePhase = .error(EnhanceError(
                title: "Microphone permission is off",
                guidance: "Dictation needs the mic. Open System Settings → Privacy & Security → Microphone and enable enprompt.",
                fix: .privacyPane
            ))
            DebugLogger.log("DICTATION FAILED: no microphone permission")
            return
        }
        guard speech else {
            enhancePhase = .error(EnhanceError(
                title: "Speech recognition permission is off",
                guidance: "Open System Settings → Privacy & Security → Speech Recognition and enable enprompt.",
                fix: .privacyPane
            ))
            DebugLogger.log("DICTATION FAILED: no speech recognition permission")
            return
        }

        isListening = true
        dictationFinished = false
        dictationSession += 1
        let session = dictationSession
        enhancePhase = .listening("")
        DebugLogger.log("DICTATION STARTED (session \(session))")

        transcriber.onPartial = { [weak self] text in
            Task { @MainActor in
                self?.enhancePhase = .listening(text)
            }
        }
        transcriber.onFinal = { [weak self] result in
            Task { @MainActor in
                self?.finishDictation(result: result, session: session)
            }
        }
        transcriber.start()
    }

    func stopDictation() {
        transcriber.stop()
    }

    private func finishDictation(result: Result<String, Error>, session: Int) {
        // Ignore callbacks from a previous dictation session (a late final
        // result must never paste text on its own or start a new session).
        guard session == dictationSession else { return }
        guard !dictationFinished else { return }
        dictationFinished = true
        isListening = false
        switch result {
        case .success(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                enhancePhase = .error(EnhanceError(
                    title: "No speech detected",
                    guidance: "Hold ⌥, then speak closer to the mic and release to insert.",
                    fix: nil
                ))
                DebugLogger.log("DICTATION: no speech")
                return
            }
            DebugLogger.log("DICTATED \(trimmed.count) chars: \(trimmed.prefix(120))")

            // Insert the transcript at the cursor of the focused field.
            if let input = AXService.focusedTextInput() {
                var appPID: pid_t = 0
                AXUIElementGetPid(input.element, &appPID)
                KeyboardInputService.pasteText(trimmed, in: appPID == 0 ? nil : appPID)
                enhancePhase = .success("Dictated \(trimmed.count) chars")
                DebugLogger.log("DICTATION INSERTED into focused field")
            } else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(trimmed, forType: .string)
                enhancePhase = .success("Dictated \(trimmed.count) chars - copied to clipboard")
                DebugLogger.log("DICTATION: no focused field, copied to clipboard")
            }
        case .failure(let error):
            enhancePhase = .error(Self.enhanceError(from: error))
            DebugLogger.log("DICTATION FAILED: \(error.localizedDescription)")
        }
    }

    // MARK: - Visual capture (triple-tap ⌥ → draw → speak → prompt)

    func setVisualCaptureEnabled(_ enabled: Bool) {
        visualCaptureEnabled = enabled
        defaults.set(enabled, forKey: "visualCaptureEnabled")
    }

    /// Entry point from the triple-tap: remembers the focused field, then
    /// shows the drawing canvas.
    func startVisualCapture() {
        guard visualCaptureEnabled else {
            DebugLogger.log("VISUAL CAPTURE: disabled in Settings")
            return
        }
        guard config.isConfigured else {
            enhancePhase = .error(EnhanceError(
                title: "No AI provider is set up yet",
                guidance: "Open Settings and paste your API key - or pick Ollama for a free local setup.",
                fix: .llm
            ))
            DebugLogger.log("VISUAL CAPTURE: no LLM configured")
            return
        }
        guard !isListening, !isEnhancing else { return }
        // The canvas is already up: another triple-tap must never stack a
        // second fullscreen canvas window.
        guard !canvas.isShowing else {
            DebugLogger.log("VISUAL CAPTURE: canvas already showing - ignoring triple-tap")
            return
        }

        if !ScreenCapture.isAuthorized {
            Task { await ScreenCapture.requestPermission() }
            enhancePhase = .error(EnhanceError(
                title: "Screen Recording permission is off",
                guidance: "Click Allow on the system prompt that just appeared (enprompt restarts itself), then try again.",
                fix: .privacyPane
            ))
            DebugLogger.log("VISUAL CAPTURE: no screen recording permission")
            return
        }

        visualCaptureFocus = AXService.focusedTextInput()
        visualCaptureDone = false
        DebugLogger.log("VISUAL CAPTURE: showing canvas")

        // Warm the local vision model while the user draws and speaks: Ollama
        // loads models into memory on first use (can take seconds), and that
        // load would otherwise happen after Esc, right before the prompt call.
        if provider == .ollama {
            let model = visionModel.isEmpty ? LLMClient.visionModel(for: .ollama) : visionModel
            Task {
                do {
                    try await LLMClient.warmUp(baseURL: baseURL, model: model)
                    DebugLogger.log("VISUAL CAPTURE: warmed \(model)")
                } catch {
                    DebugLogger.log("VISUAL CAPTURE: warm-up failed (ignored): \(error.localizedDescription)")
                }
            }
        }

        canvas.onFinish = { [weak self] strokes, transcript in
            self?.canvasFinished(strokes: strokes, transcript: transcript)
        }
        canvas.onCancelled = { [weak self] in
            DebugLogger.log("VISUAL CAPTURE: cancelled")
            self?.enhancePhase = .idle
        }
        canvas.show()
    }

    /// The canvas is done: capture the annotated screenshot, ask the vision
    /// model for the perfect prompt, paste it, and save it to history.
    private func canvasFinished(strokes: [CanvasStroke], transcript: String) {
        guard !visualCaptureDone else { return }
        visualCaptureDone = true
        let focus = visualCaptureFocus
        visualCaptureFocus = nil

        DebugLogger.log("VISUAL CAPTURE: \(strokes.count) strokes + '\(transcript.prefix(120))'")
        guard let screen = NSScreen.main else { return }

        Task {
            enhancePhase = .enhancing(0)
            // 640px max keeps the screenshot readable while cutting image
            // tokens roughly in half vs. 700px - faster to process, and the
            // model answers sooner.
            guard
                let jpeg = await ScreenCapture.captureFullScreenJPEG(maxDimension: 640, quality: 0.45),
                let image = CGImageSourceCreateWithData(jpeg as CFData, nil).flatMap({
                    CGImageSourceCreateImageAtIndex($0, 0, nil)
                })
            else {
                enhancePhase = .error(EnhanceError(
                    title: "Screen capture failed",
                    guidance: "Make sure Screen Recording is allowed in System Settings → Privacy & Security, then try again.",
                    fix: .privacyPane
                ))
                DebugLogger.log("VISUAL CAPTURE: capture returned nil")
                return
            }
            let annotated = ScreenCapture.composite(
                strokes: strokes,
                screenSize: screen.frame.size,
                onto: image
            )
            let rep = NSBitmapImageRep(cgImage: annotated)
            guard let annotatedJPEG = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.55]) else {
                enhancePhase = .error(EnhanceError(
                    title: "Screen capture failed",
                    guidance: "Please try again.",
                    fix: nil
                ))
                return
            }

            do {
                let prompt = try await LLMClient.promptWithVision(
                    instruction: transcript,
                    imageData: annotatedJPEG,
                    config: config
                )
                recordUsage(
                    promptText: LLMClient.visionSystemPrompt + "\n" + transcript,
                    completionText: prompt,
                    imagePixels: rep.pixelsWide * rep.pixelsHigh
                )
                let targetPID = focus.flatMap { $0.appPID } ?? 0
                KeyboardInputService.pasteText(prompt, in: targetPID == 0 ? nil : targetPID)
                saveCapturedPrompt(prompt)
                // Always mirror the prompt into the clipboard, so it's there
                // even if paste into the focused field didn't land - the
                // toast tells the user it's ready to paste anywhere.
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
                enhancePhase = .success("Pasted, saved & copied to clipboard (\(prompt.count) chars)")
                DebugLogger.log("VISUAL CAPTURE: pasted + saved + copied \(prompt.count) chars")
            } catch {
                enhancePhase = .error(Self.enhanceError(from: error))
                DebugLogger.log("VISUAL CAPTURE FAILED: \(error.localizedDescription)")
            }
        }
    }

    /// Esc while the visual-capture canvas is up: finish it. Routes through
    /// the canvas even when the canvas window isn't the key window, and
    /// swallows the key so the focused app doesn't react to it.
    func handleVisualCaptureEscape() -> Bool {
        guard canvas.isShowing else { return false }
        DebugLogger.log("CANVAS: global Esc routed to canvas")
        canvas.escapePressed()
        return true
    }

    // MARK: - Captured prompts history

    private func saveCapturedPrompt(_ prompt: String) {
        capturedPrompts.insert(prompt, at: 0)
        if capturedPrompts.count > 15 {
            capturedPrompts.removeLast(capturedPrompts.count - 15)
        }
        defaults.set(capturedPrompts, forKey: "capturedPrompts")
    }

    func copyCapturedPrompt(at index: Int) {
        guard capturedPrompts.indices.contains(index) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(capturedPrompts[index], forType: .string)
        DebugLogger.log("CAPTURED PROMPT copied (\(capturedPrompts[index].count) chars)")
    }

    func removeCapturedPrompt(at index: Int) {
        guard capturedPrompts.indices.contains(index) else { return }
        capturedPrompts.remove(at: index)
        defaults.set(capturedPrompts, forKey: "capturedPrompts")
        DebugLogger.log("CAPTURED PROMPT removed")
    }
}