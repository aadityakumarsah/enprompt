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

            HStack(spacing: 4) {
                Keycap("⌥", key: "Option")
                Keycap("⌥", key: "Option")
                Text("expand")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Keycap("⌥", key: "Option")
                Text("hold 1.25s + speak")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Keycap("⌥", key: "Option")
                Keycap("⌥", key: "Option")
                Keycap("⌥", key: "Option")
                Text("draw + speak")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)

            Button {
                Task { await state.enhanceFocusedText() }
            } label: {
                Label("Enhance focused text", systemImage: "wand.and.stars")
                    .font(.callout)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(state.isEnhancing)
            .help("Runs the same enhancement as a ⌥⌥ double-tap - handy when the gesture misses")

            if state.isEnhancing {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Enhancing text via LLM...")
                        .font(.caption)
                }
            } else if case .success(let message) = state.enhancePhase {
                Label(message, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if case .error(let message) = state.enhancePhase {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text("Double-tap ⌥ to expand text, hold ⌥ and speak for dictation, triple-tap ⌥ for the canvas: draw over the screen (pen, shapes, laser) while the mic listens live - press Esc to combine your drawing, the screenshot and your words into one prompt, pasted and saved under Captured prompts.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

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
            Task { await state.checkForUpdates() }
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