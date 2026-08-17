import SwiftUI

/// Renders the enprompt logo from the bundle's icon.icns so the popover and
/// menu bar always show the real app icon.
struct AppIconView: View {
    var size: CGFloat = 36

    private var image: NSImage? {
        guard let url = Bundle.main.url(forResource: "icon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.25))
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [.red, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
        }
    }
}

struct EnpromptMenuView: View {

    @EnvironmentObject private var state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AppIconView(size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("enprompt")
                        .font(.headline)
                    Text("Focused-text assistant")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                trustBadge
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ShortcutChip(keys: "⌥⌥", label: "Enhance selected text")
                    ShortcutChip(keys: "⌥ T", label: "Teach me")
                }
                HStack(spacing: 10) {
                    ShortcutChip(keys: "⌥ hold", label: "Speak → dictation")
                    ShortcutChip(keys: "⌥⌥⌥", label: "Canvas: draw + speak")
                }
            }
            .frame(maxWidth: .infinity)

            if state.isReplyPromptActive {
                HStack(spacing: 8) {
                    Menu {
                        ForEach(AppState.replyPresetNames, id: \.self) { name in
                            Button(name) {
                                Task { await state.prepareReply(preset: name) }
                            }
                        }
                        Divider()
                        Button("Custom prompt (saved)") {
                            Task { await state.prepareReply(preset: nil) }
                        }
                    } label: {
                        Label("Prepare reply", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isEnhancing)
                    .help("Select any post text, pick a reply style, and the reply lands on your clipboard - ⌘V to paste")

                    Button {
                        if state.isSpeaking {
                            state.stopAll()
                        } else {
                            state.startTeach()
                        }
                    } label: {
                        Label(state.isSpeaking ? "Stop" : "Teach me", systemImage: state.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(state.isSpeaking ? .red : nil)
                    .disabled(state.isTeaching || !state.teachEnabled)
                    .help(state.isSpeaking
                        ? "Stop the voice right now"
                        : "Explains the selected text like a five-year-old would understand - every detail, nothing left out - then speaks it in a natural local voice (shortcut: hold ⌥ and press T). Optional: turn it off in Settings.")

                    if let active = state.activePresetName {
                        Text(active)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        state.startEnhance()
                    } label: {
                        Label("Enhance", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isEnhancing)
                    .help("Runs the same enhancement as a ⌥⌥ double-tap")

                    Button {
                        if state.isSpeaking {
                            state.stopAll()
                        } else {
                            state.startTeach()
                        }
                    } label: {
                        Label(state.isSpeaking ? "Stop" : "Teach me", systemImage: state.isSpeaking ? "stop.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(state.isSpeaking ? .red : nil)
                    .disabled(state.isTeaching || !state.teachEnabled)
                    .help(state.isSpeaking
                        ? "Stop the voice right now"
                        : "Explains the selected text like a five-year-old would understand - every detail, nothing left out - then speaks it in a natural local voice (shortcut: hold ⌥ and press T). Optional: turn it off in Settings.")
                }
            }

            if state.isEnhancing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing via LLM...")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stopButton
                }
            } else if state.isTeaching {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Explaining like you're five...")
                        .font(.caption)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    stopButton
                }
            } else if case .success(let message) = state.enhancePhase {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .error(let error) = state.enhancePhase {
                EnhanceErrorCard(error: error, openSettings: { openSettings() })
            }

            if !state.teachText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Label(
                            state.isTeaching
                                ? "Writing the \(state.activeTeachLanguage.label) explanation…"
                                : "\(state.activeTeachLanguage.label) explanation",
                            systemImage: state.isTeaching ? "pencil.and.outline" : "speaker.wave.2.fill"
                        )
                        .font(.caption)
                        .fontWeight(.semibold)
                        Spacer()
                        if state.isTeaching {
                            Text("\(state.teachText.count) chars")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        } else if state.isSpeaking {
                            Button {
                                state.stopAll()
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .help("Stop the voice right now")
                        } else {
                            Button {
                                state.speakTeachAgain()
                            } label: {
                                Label("Listen again", systemImage: "play.fill")
                            }
                            .controlSize(.mini)
                            .buttonStyle(.bordered)
                            .help("Speak the same explanation again")
                        }
                    }
                    ScrollView {
                        Text(state.teachText)
                            .font(.caption)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                    .padding(6)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.08))
                    )
                    Text("Also copied to your clipboard - ⌘V to paste it anywhere")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            ollamaSetupBanner

            Divider()

            if !state.capturedPrompts.isEmpty {
                Text("Captured prompts")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                ForEach(Array(state.capturedPrompts.prefix(5).enumerated()), id: \.offset) { index, prompt in
                    HStack(spacing: 6) {
                        Text(prompt)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help(prompt)
                        Spacer()
                        Button {
                            state.copyCapturedPrompt(at: index)
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Copy to clipboard")
                        Button {
                            state.removeCapturedPrompt(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                    .padding(.vertical, 2)
                }
                Divider()
            }

            HStack(spacing: 6) {
                Text("Tokens")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text("≈\(state.sessionTokens.formatted()) this session")
                    .font(.caption)
                Text("·")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("≈\(state.totalTokens.formatted()) total")
                    .font(.caption)
                Spacer()
                Button("Reset") {
                    state.resetTokenUsage()
                }
                .controlSize(.mini)
                .buttonStyle(.borderless)
                .help("Reset the token counters")
            }

            Divider()

            HStack(spacing: 8) {
                Circle()
                    .fill(state.apiKey.isEmpty ? Color.orange : Color.green)
                    .frame(width: 8, height: 8)
                Text(state.apiKey.isEmpty ? "No API key" : "\(state.provider.displayName) · \(state.model)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Text("Change")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.blue)
            }
            .padding(6)
            .contentShape(Rectangle())
            .onTapGesture {
                openSettings()
            }
            .help("Click to change the API key or provider")

            if let update = state.updateInfo {
                HStack(spacing: 8) {
                    Label("enprompt \(update.version) available", systemImage: "arrow.down.circle.fill")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.blue)
                        .lineLimit(1)
                    Spacer()
                    Button {
                        state.downloadAndInstallUpdate()
                    } label: {
                        if state.isDownloadingUpdate {
                            ProgressView()
                                .controlSize(.mini)
                                .frame(width: 44)
                        } else {
                            Label("Update now", systemImage: "arrow.down.circle")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(state.isDownloadingUpdate)
                    .help("Downloads the update, replaces this app, and relaunches")
                    Button("Later") { state.dismissUpdate() }
                        .buttonStyle(.borderless)
                        .controlSize(.mini)
                }
            }

            HStack {
                Spacer()
                Button("Settings…") {
                    openSettings()
                }
                Button("Quit enprompt") {
                    NSApp.terminate(nil)
                }
            }
            .controlSize(.small)

            Text("enprompt v\(UpdateChecker.currentVersion ?? "?")")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(width: 340)
        .onAppear {
            state.refreshTrust()
            // Force a fresh check on popover open: without `force` the hourly
            // throttle can hide a just-published release for up to an hour.
            Task { await state.checkForUpdates(force: true) }
            if state.provider == .ollama {
                Task { await state.loadOllamaModels() }
            }
        }
    }

    private var trustBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(state.isAccessibilityTrusted ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text(state.isAccessibilityTrusted ? "Accessible" : "Not trusted")
                .font(.caption)
        }
    }

    /// Stops the in-flight LLM call and any speaking voice at once.
    private var stopButton: some View {
        Button {
            state.stopAll()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .controlSize(.mini)
        .buttonStyle(.bordered)
        .tint(.red)
        .help("Cancel the explanation and stop the voice")
    }

    /// One-click free local setup, right in the popover: when the user runs
    /// enprompt on the free Ollama provider but the models aren't installed
    /// yet, this banner appears with a single Install button - the text model
    /// and the vision model download at the same time with a live progress
    /// bar, and enprompt picks them automatically when done.
    @ViewBuilder
    private var ollamaSetupBanner: some View {
        if state.provider == .ollama, !state.ollamaInstalling,
           (state.ollamaModels.isEmpty || !state.ollamaModels.contains(where: LLMClient.isVisionModel)) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Free local models aren't installed yet", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.orange)
                Text("One click installs the free Ollama app (if missing) + llama3.2 (text) + qwen2.5vl (vision) at the same time and sets them up - no terminal, no browser, nothing to drag.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    Task { await state.installOllamaModels() }
                } label: {
                    Label("Install everything (free)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Downloads the Ollama app (~190 MB) if missing, then the text model (~2 GB) + vision model (~6 GB) at the same time, and selects them automatically")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.orange.opacity(0.25))
                    )
            )
        } else if state.provider == .ollama, state.ollamaInstalling {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.ollamaSetupPhase ?? "Installing…")
                        .font(.caption)
                        .fontWeight(.semibold)
                    Spacer()
                    if state.ollamaInstallProgress >= 1 {
                        Label("Done", systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                }
                ProgressView(value: state.ollamaInstallProgress)
                    .progressViewStyle(.linear)
                Text("enprompt installs the Ollama app (if needed) and both models by itself - keep this open, it sets everything up when the progress hits 100%.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.orange.opacity(0.25))
                    )
            )
        }
    }
}

/// Friendly error card: a short title, what to do about it, and a one-click
/// shortcut to the right Settings section when one exists.
private struct EnhanceErrorCard: View {

    let error: EnhanceError
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(error.title, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.orange)
            Text(error.guidance)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if error.fix != nil {
                Button("Open Settings", action: openSettings)
                    .controlSize(.mini)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.orange.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.orange.opacity(0.25))
                )
        )
    }
}

/// Small keycap pill used to show keyboard shortcuts (e.g. the Option key).
struct Keycap: View {
    let glyph: String
    let key: String

    init(_ glyph: String, key: String) {
        self.glyph = glyph
        self.key = key
    }

    var body: some View {
        Text(glyph)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .strokeBorder(Color.gray.opacity(0.3))
                    )
            )
            .help(key)
    }
}

/// One entry in the gesture cheat-sheet: a keycap pill plus its action.
struct ShortcutChip: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Keycap(keys, key: label)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}