import AppKit
import Combine
import SwiftUI

/// Floating top-center panel that shows enhance progress so the user always
/// knows what enprompt is doing, without needing the popover open.
///
/// The window is created once and hosts a single SwiftUI root that observes
/// `AppState.enhancePhase` itself. Phases only show/hide/resize the window -
/// the view updates in place, so there is no flicker and the dictation
/// transcript keeps its scroll position while the user is speaking.
@MainActor
final class EnhanceOverlayController: NSObject {

    private var window: NSWindow?
    private var cancellable: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    private static let defaultSize = NSSize(width: 360, height: 80)
    private static let listeningSize = NSSize(width: 560, height: 180)

    func install() {
        let window = NonKeyWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = true

        let hosting = NSHostingController(
            rootView: EnhanceOverlayRoot().environmentObject(AppState.shared)
        )
        // The window owns its size (see handle(_:)); the SwiftUI content must
        // never dictate it, otherwise long dictation partials would grow the
        // overlay past the screen edge.
        hosting.sizingOptions = []
        window.contentViewController = hosting

        self.window = window

        cancellable = AppState.shared.$enhancePhase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                MainActor.assumeIsolated {
                    self?.handle(phase)
                }
            }
    }

    private func handle(_ phase: EnhancePhase) {
        hideTask?.cancel()
        switch phase {
        case .idle:
            hideWindow()
        case .listening:
            resize(Self.listeningSize)
            showWindow()
        case .enhancing, .success:
            resize(Self.defaultSize)
            showWindow()
            if case .success = phase {
                DebugLogger.log("OVERLAY show: success")
                scheduleHide(after: 3)
            }
        case .error:
            resize(Self.defaultSize)
            showWindow()
            DebugLogger.log("OVERLAY show: error")
            scheduleHide(after: 4)
        }
    }

    private func scheduleHide(after seconds: Double) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await MainActor.run {
                self?.hideWindow()
            }
        }
    }

    private func resize(_ size: NSSize) {
        guard let window else { return }
        let screenWidth = NSScreen.main?.frame.width ?? 1920
        var clamped = size
        clamped.width = min(clamped.width, screenWidth - 60)
        if window.frame.size != clamped {
            window.setContentSize(clamped)
            positionTopCenter(window)
        }
    }

    private func showWindow() {
        guard let window else { return }
        if window.isVisible {
            window.orderFrontRegardless()
            return
        }
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 1
        }
    }

    private func hideWindow() {
        guard let window, window.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
        }
    }

    private func positionTopCenter(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        let size = window.frame.size
        let x = (screen.frame.width - size.width) / 2
        let y = screen.frame.height - size.height - 60
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// Root view: re-renders whenever the phase changes, without the controller
/// touching the window content.
struct EnhanceOverlayRoot: View {

    @EnvironmentObject private var state: AppState

    var body: some View {
        EnhanceOverlayView(phase: state.enhancePhase)
    }
}

/// Borderless window that can never become key: it must not steal keyboard
/// or accessibility focus from the app the user is typing in.
private final class NonKeyWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct EnhanceOverlayView: View {

    let phase: EnhancePhase

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case .enhancing(let chars):
                ProgressView()
                    .controlSize(.small)
                Text(chars > 0 ? "Enhancing… \(chars) chars" : "Enhancing…")
                    .font(.callout)
                Spacer(minLength: 0)

            case .listening(let partial):
                ZStack {
                    Circle()
                        .fill(.red.opacity(0.15))
                        .frame(width: 34, height: 34)
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text("Listening")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                        Text("\(partial.count) chars")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.8))
                        Spacer()
                        Text("release ⌥ to insert")
                            .font(.caption2)
                            .foregroundStyle(.secondary.opacity(0.6))
                    }
                    if partial.isEmpty {
                        Spacer()
                        Text("Hold ⌥ for 1.25s, then speak…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        ScrollViewReader { proxy in
                            ScrollView {
                                Text(partial)
                                    .font(.callout)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("transcript")
                            }
                            .onChange(of: partial) { _, _ in
                                proxy.scrollTo("transcript", anchor: .bottom)
                            }
                        }
                    }
                }

            case .success(let message):
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.callout)
                    .lineLimit(2)
                Spacer(minLength: 0)

            case .error(let error):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.title)
                        .font(.callout)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                    Text(error.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)

            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.15)))
        .shadow(radius: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}