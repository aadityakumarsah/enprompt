import AppKit
import SwiftUI

struct SettingsView: View {

    @EnvironmentObject private var state: AppState

    /// True once the user picks "Custom" in the preset dropdown. Needed because
    /// the dropdown selection is derived from the prompt text, and picking
    /// "Custom" does not change that text - without this flag the Picker
    /// snaps back to the matching preset (e.g. "default") immediately.
    @State private var isCustomMode = false

    /// Live feedback under the API key field as the user pastes a key.
    private var detectedLabel: (text: String, icon: String, color: Color) {
        let trimmed = state.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return ("Paste a key to detect the provider", "key.fill", .secondary)
        }
        if let provider = LLMProvider.providerForAPIKey(trimmed) {
            return ("\(provider.displayName) detected", "checkmark.seal.fill", .green)
        }
        return ("Couldn't detect the provider from this key", "questionmark.circle.fill", .orange)
    }

    private var systemPromptSelection: Binding<String> {
        Binding(
            get: {
                if isCustomMode { return "custom" }
                if state.systemPrompt == LLMClient.defaultSystemPrompt { return "default" }
                for (name, prompt) in LLMClient.promptPresets where prompt == state.systemPrompt {
                    return name
                }
                return "custom"
            },
            set: { selection in
                if selection == "default" {
                    isCustomMode = false
                    state.systemPrompt = LLMClient.defaultSystemPrompt
                } else if let prompt = LLMClient.promptPresets[selection] {
                    isCustomMode = false
                    state.systemPrompt = prompt
                } else {
                    isCustomMode = true
                }
            }
        )
    }

    var body: some View {
        Form {
            Section {
                let allGranted = state.isAccessibilityTrusted
                    && state.screenRecordingGranted
                    && state.microphoneGranted
                    && state.speechGranted
                if allGranted {
                    Label("All permissions granted - enprompt is fully set up", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("Grant the four permissions below once - enprompt does everything else. After you allow Screen Recording, enprompt restarts itself automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !state.isAccessibilityTrusted || !state.screenRecordingGranted {
                        Label("Finish setup so enprompt can read your text and capture the screen", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                permissionRow(
                    title: "Accessibility",
                    granted: state.isAccessibilityTrusted,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
                    detail: "Needed to read and write text in any app"
                )
                permissionRow(
                    title: "Screen Recording",
                    granted: state.screenRecordingGranted,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                    detail: "Needed for the drawing canvas - enprompt restarts itself after you allow it"
                )
                permissionRow(
                    title: "Microphone",
                    granted: state.microphoneGranted,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                    detail: "Needed for dictation and canvas voice"
                )
                permissionRow(
                    title: "Speech Recognition",
                    granted: state.speechGranted,
                    pane: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition",
                    detail: "Needed to transcribe what you say"
                )
                if !state.screenRecordingGranted {
                    Button("Restart enprompt now") {
                        state.relaunchAfterPermissionGrant()
                    }
                }
            } header: {
                Text("Setup")
            }

            Section("Behavior") {
                Toggle("Start enprompt at login", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .help("enprompt always stays on: launches at login, keeps running, and restarts if it crashes. Turn this off to disable auto-start.")
                Toggle("Visual capture (⌥⌥⌥)", isOn: Binding(
                    get: { state.visualCaptureEnabled },
                    set: { state.setVisualCaptureEnabled($0) }
                ))
                .help("Triple-tap ⌥ to open the canvas: the mic starts automatically - draw over the screen (pen, shapes, laser that fades) while you speak (your words shown live). Press Esc to generate: the annotated screenshot + your voice become one precise prompt, pasted and saved.")
                Text("Double-tap the ⌥ Option key to expand the text you're typing via the LLM. Hold ⌥ Option for 1.25 seconds, then speak - release to insert at your cursor. Triple-tap ⌥ to open the drawing canvas: the mic listens automatically - draw over the screen and speak at the same time. Press Esc to finish: the screenshot with your annotations and your voice become one precise prompt, pasted into your input and saved under Captured prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                if !state.apiKey.isEmpty && !state.llmSetupExpanded {
                    // Minimal status: the setup form is hidden until the user
                    // clicks to change the API key or provider.
                    LabeledContent("Connected") {
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(state.provider.displayName)
                                    .font(.callout)
                                Text(state.model)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button("Change") {
                                state.llmSetupExpanded = true
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("enprompt is connected to \(state.provider.displayName). Click Change to switch providers or update your API key - it is stored securely in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    SecureField("API key", text: $state.apiKey)
                        .textFieldStyle(.roundedBorder)
                    if !state.apiKey.isEmpty {
                        Label(detectedLabel.text, systemImage: detectedLabel.icon)
                            .font(.caption)
                            .foregroundStyle(detectedLabel.color)
                    }
                    HStack {
                        Button("Save") {
                            Task {
                                if await state.saveAPIKey(state.apiKey) {
                                    DebugLogger.log("SETTINGS: key saved after validation")
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Test connection") {
                            Task { await state.testLLM() }
                        }
                        if !state.apiKey.isEmpty {
                            Spacer()
                            Button("Cancel") {
                                state.llmSetupExpanded = false
                            }
                        }
                    }
                    if let testStatus = state.testStatus {
                        Label(testStatus.message, systemImage: testStatus.isError ? "xmark.circle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(testStatus.isError ? .red : .green)
                    }
                    Text("Paste your API key and hit Save - enprompt detects the provider automatically (Claude, ChatGPT/Codex, OpenRouter or Gemini), sets everything up, and tests the key against the real API before saving. Nothing else is needed. The key is stored in your Keychain.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("LLM")
            }

            Section {
                Picker("Preset", selection: systemPromptSelection) {
                    Text("Polished rewrite (default)").tag("default")
                    ForEach(Array(LLMClient.promptPresets.keys), id: \.self) { name in
                        Text(name).tag(name)
                    }
                    Text("Custom").tag("custom")
                }
                PromptEditor(text: $state.systemPrompt)
                    .frame(height: 180)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.gray.opacity(0.4)))
                    .overlay(alignment: .topLeading) {
                        if state.systemPrompt.isEmpty {
                            Text("Type your own system prompt here…")
                                .font(.caption)
                                .foregroundStyle(.secondary.opacity(0.6))
                                .padding(6)
                        }
                    }
                HStack {
                    Button("Reset to default") {
                        state.systemPrompt = LLMClient.defaultSystemPrompt
                    }
                    Button("Clear") {
                        state.systemPrompt = ""
                    }
                    Button("Save") {
                        state.persistConfig()
                    }
                    .buttonStyle(.borderedProminent)
                }
                if systemPromptSelection.wrappedValue == "custom" {
                    Text("Custom mode is active: this exact prompt is sent to the model with every enhancement. Edit it above and hit Save - no preset needed.")
                        .font(.caption)
                        .foregroundStyle(.blue)
                } else {
                    Text("This system prompt is sent to the model with every enhance. Choose a preset, or pick Custom and write your own - prompt engineering, enprompt style.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Admin - System Prompt")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
        .onAppear { state.refreshPermissions() }
        .onChange(of: state.systemPrompt) { _, newValue in
            // Editing the box to text that matches no preset means the user is
            // writing their own prompt: switch the dropdown to "Custom".
            let isPreset = newValue == LLMClient.defaultSystemPrompt
                || LLMClient.promptPresets.values.contains(newValue)
            if !isPreset && !isCustomMode {
                isCustomMode = true
            }
        }
    }

    private func permissionRow(title: String, granted: Bool, pane: String, detail: String) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(granted ? .green : .red)
                    Text(granted ? "Granted" : "Not granted")
                        .font(.callout)
                }
                if !granted {
                    Button("Open System Settings") {
                        if let url = URL(string: pane) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .controlSize(.small)
                } else {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// NSTextView wrapper for the custom system prompt. SwiftUI's TextEditor
/// inside a Form often never gains first responder on click on macOS, so
/// nothing can be typed; NSTextView accepts focus natively.
private struct PromptEditor: NSViewRepresentable {

    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.delegate = context.coordinator
            textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            textView.isRichText = false
            textView.textContainerInset = NSSize(width: 4, height: 6)
            textView.string = text
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PromptEditor
        init(_ parent: PromptEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                parent.text = textView.string
            }
        }
    }
}