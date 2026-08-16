import AppKit
import Foundation

/// A stroke drawn on the visual capture canvas: a freehand pen path, a shape
/// (rect / ellipse / triangle / arrow) between two points, or a laser trail
/// that fades out shortly after being drawn.
struct CanvasStroke {
    enum ShapeKind {
        case pen, rect, ellipse, triangle, arrow
    }

    var shape: ShapeKind
    /// Freehand points (pen/laser) in view coordinates (bottom-left origin).
    var points: [CGPoint] = []
    /// Shape anchors (rect/ellipse/triangle/arrow) in view coordinates.
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var color: NSColor = .systemOrange
    var width: CGFloat = 4
    /// Laser strokes vanish after this time; nil = permanent.
    var expiresAt: CFAbsoluteTime?
}

/// Full-screen canvas for visual capture: the user draws (pen, shapes, laser)
/// over the live screen, presses Enter to speak their instruction (with the
/// transcript shown live), and presses Enter again to generate.
@MainActor
final class CanvasController: NSObject {

    enum Tool: Int, CaseIterable {
        case pen, laser, rect, ellipse, triangle, arrow
        var label: String {
            switch self {
            case .pen: return "Pen (1)"
            case .laser: return "Laser (2)"
            case .rect: return "Rect (3)"
            case .ellipse: return "Circle (4)"
            case .triangle: return "Triangle (5)"
            case .arrow: return "Arrow (6)"
            }
        }
    }

    /// Finished with the drawing + spoken instruction.
    var onFinish: ((_ strokes: [CanvasStroke], _ transcript: String) -> Void)?
    /// Cancelled without generating.
    var onCancelled: (() -> Void)?

    private var window: NSWindow?
    private weak var canvasView: CanvasView?
    private(set) var isShowing = false

    func show() {
        guard let screen = NSScreen.main else { return }
        isShowing = true
        let frame = screen.frame
        // Borderless NSWindows cannot become the key window by default, so
        // keyboard input (Esc/Enter) would never reach the canvas. This
        // subclass opts back in.
        let window = CanvasWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true

        let view = CanvasView(frame: frame)
        view.onFinish = { [weak self] strokes, transcript in
            self?.hide()
            self?.onFinish?(strokes, transcript)
        }
        view.onCancelled = { [weak self] in
            self?.hide()
            self?.onCancelled?()
        }
        window.contentView = view
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        canvasView = view
        self.window = window
    }

    func hide() {
        isShowing = false
        canvasView?.shutdown()
        window?.orderOut(nil)
        window = nil
        canvasView = nil
    }

    /// Esc pressed while the canvas is open but the canvas window is not the
    /// key window (focus elsewhere): route to the same finish flow as the
    /// canvas's own keyDown handler.
    func escapePressed() {
        canvasView?.finishCanvas()
    }
}

@MainActor
private final class CanvasWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The drawing surface: dims the screen, hosts a tool bar, handles mouse
/// drawing, keyboard shortcuts, the laser fade-out timer, and the live
/// transcript while listening.
@MainActor
private final class CanvasView: NSView {

    var onFinish: ((_ strokes: [CanvasStroke], _ transcript: String) -> Void)?
    var onCancelled: (() -> Void)?

    private(set) var strokes: [CanvasStroke] = []
    private var currentStroke: CanvasStroke?
    private var tool: CanvasController.Tool = .pen
    private var transcript = ""
    private var listenError: String?
    private var finishRequested = false
    private var didFinish = false

    private let transcriber = SpeechTranscriber()
    private var laserTimer: Timer?
    private var toolButtons: [CanvasController.Tool: NSButton] = [:]

    private static let laserLifetime: TimeInterval = 2.5

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        buildToolbar()
        // The mic starts the moment the canvas opens: the user draws and
        // speaks at the same time.
        startListening()
    }

    private func buildToolbar() {
        for sub in subviews { sub.removeFromSuperview() }
        toolButtons = [:]

        let buttonSize = NSSize(width: 74, height: 26)
        var x = 0.0
        let y = bounds.height - 52
        for tool in CanvasController.Tool.allCases {
            let button = NSButton(title: tool.label, target: self, action: #selector(toolClicked(_:)))
            button.tag = tool.rawValue
            button.frame = NSRect(x: 10 + x, y: y, width: buttonSize.width, height: buttonSize.height)
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.bezelStyle = .rounded
            addSubview(button)
            toolButtons[tool] = button
            x += buttonSize.width + 8
        }

        func extra(_ title: String, _ action: Selector, _ key: String) {
            let b = NSButton(title: title, target: self, action: action)
            b.frame = NSRect(x: 10 + x, y: y, width: 118, height: buttonSize.height)
            b.font = .systemFont(ofSize: 11, weight: .medium)
            b.bezelStyle = .rounded
            addSubview(b)
            x += 126
            _ = key
        }
        extra("Undo (Z)", #selector(undoClicked), "z")
        extra("Clear (C)", #selector(clearClicked), "c")

        let hint = NSTextField(labelWithString: "Draw & speak · Esc = generate & save")
        hint.frame = NSRect(x: 10, y: bounds.height - 88, width: bounds.width - 20, height: 20)
        hint.alignment = .center
        hint.font = .systemFont(ofSize: 12, weight: .medium)
        hint.textColor = .white
        addSubview(hint)
        updateToolHighlight()
    }

    @objc private func toolClicked(_ sender: NSButton) {
        tool = CanvasController.Tool(rawValue: sender.tag) ?? .pen
        updateToolHighlight()
    }

    @objc private func undoClicked() {
        strokes.removeLast()
        needsDisplay = true
    }

    @objc private func clearClicked() {
        strokes.removeAll()
        needsDisplay = true
    }

    private func updateToolHighlight() {
        for (tool, button) in toolButtons {
            button.state = (tool == self.tool) ? .on : .off
        }
    }

    // MARK: - Mouse drawing

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let stroke = CanvasStroke(
            shape: .pen,
            points: [p],
            start: p,
            end: p,
            color: tool == .laser ? NSColor.systemYellow : .systemOrange,
            width: tool == .laser ? 6 : 4
        )
        currentStroke = stroke
        if tool == .laser {
            startLaserTimer()
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard var stroke = currentStroke else { return }
        let p = convert(event.locationInWindow, from: nil)
        if stroke.shape == .pen {
            stroke.points.append(p)
        } else {
            stroke.end = p
        }
        currentStroke = stroke
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let stroke = currentStroke else { return }
        currentStroke = nil
        var finalStroke = stroke
        let end = convert(event.locationInWindow, from: nil)
        finalStroke.end = end

        if tool != .pen {
            finalStroke.shape = {
                switch tool {
                case .rect: return .rect
                case .ellipse: return .ellipse
                case .triangle: return .triangle
                case .arrow: return .arrow
                case .pen, .laser: return .pen
                }
            }()
            finalStroke.points = [stroke.start, end]
        }
        if tool == .laser {
            finalStroke.expiresAt = CFAbsoluteTimeGetCurrent() + Self.laserLifetime
        }
        strokes.append(finalStroke)
        needsDisplay = true
    }

    // MARK: - Laser fade-out

    private func startLaserTimer() {
        guard laserTimer == nil else { return }
        laserTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = CFAbsoluteTimeGetCurrent()
                let alive = self.strokes.filter { stroke in
                    if let expiry = stroke.expiresAt { return expiry > now }
                    return true
                }
                if alive.count != self.strokes.count {
                    self.strokes = alive
                    self.needsDisplay = true
                }
            }
        }
        RunLoop.main.add(laserTimer!, forMode: .common)
    }

    func shutdown() {
        laserTimer?.invalidate()
        laserTimer = nil
        if transcriber.isRunning {
            transcriber.stop()
        }
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 36, 76: // Esc, Return, Enter - finish and save
            finishCanvas()
        case 6: undoClicked() // Z
        case 8: clearClicked() // C
        case 37: tool = .laser; updateToolHighlight() // L
        case 18: tool = .pen; updateToolHighlight()
        case 19: tool = .rect; updateToolHighlight()
        case 20: tool = .ellipse; updateToolHighlight()
        case 21: tool = .triangle; updateToolHighlight()
        case 23: tool = .arrow; updateToolHighlight()
        default: super.keyDown(with: event)
        }
    }

    /// Esc/Enter: exit the canvas and generate. The mic keeps listening until
    /// the final transcript arrives, then everything is handed over.
    func finishCanvas() {
        DebugLogger.log("CANVAS: finish key pressed")
        guard !didFinish else { return }
        if transcriber.isRunning {
            finishRequested = true
            transcriber.stop()
        } else if !finishRequested {
            deliverFinish()
        }
    }

    private func startListening() {
        listenError = nil
        transcript = ""
        needsDisplay = true

        Task {
            let (mic, speech) = await SpeechTranscriber.requestPermissions()
            guard mic, speech else {
                listenError = "Microphone or speech permission missing - enable in System Settings"
                needsDisplay = true
                return
            }
            transcriber.onPartial = { [weak self] text in
                Task { @MainActor in
                    self?.transcript = text
                    self?.needsDisplay = true
                }
            }
            transcriber.onFinal = { [weak self] result in
                Task { @MainActor in
                    self?.finalTranscriptArrived(result)
                }
            }
            transcriber.start()
        }
    }

    /// The final transcript has arrived (or failed).
    private func finalTranscriptArrived(_ result: Result<String, Error>) {
        switch result {
        case .success(let text):
            transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            deliverFinish()
        case .failure(let error):
            listenError = "Couldn't hear you: \(error.localizedDescription)"
            if finishRequested {
                deliverFinish()
            } else {
                needsDisplay = true
            }
        }
    }

    /// Hands the drawing + transcript over. With neither strokes nor speech,
    /// the capture is treated as accidental and discarded.
    private func deliverFinish() {
        guard !didFinish else { return }
        didFinish = true
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLogger.log("CANVAS: delivering finish (strokes \(strokes.count), speech \(trimmed.count))")
        if strokes.isEmpty && trimmed.isEmpty {
            onCancelled?()
        } else {
            onFinish?(strokes, trimmed)
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        for stroke in strokes {
            drawStroke(stroke)
        }
        if let current = currentStroke {
            drawStroke(current)
        }

        // Live transcript while speaking / after finishing.
        if !transcript.isEmpty || listenError != nil {
            let box = NSRect(x: bounds.midX - 350, y: 30, width: 700, height: 90)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: box, xRadius: 12, yRadius: 12).fill()

            let text = listenError ?? transcript
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 16, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let string = NSAttributedString(string: text, attributes: attrs)
            let size = string.size()
            string.draw(in: NSRect(
                x: box.midX - min(size.width, 660) / 2,
                y: box.midY - size.height / 2,
                width: min(size.width, 660),
                height: size.height
            ))
        }
    }

    private func drawStroke(_ stroke: CanvasStroke) {
        let path = NSBezierPath()
        switch stroke.shape {
        case .pen:
            guard let first = stroke.points.first else { return }
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.line(to: point)
            }
        case .rect:
            path.appendRect(NSRect(
                x: min(stroke.start.x, stroke.end.x),
                y: min(stroke.start.y, stroke.end.y),
                width: abs(stroke.end.x - stroke.start.x),
                height: abs(stroke.end.y - stroke.start.y)
            ))
        case .ellipse:
            path.appendOval(in: NSRect(
                x: min(stroke.start.x, stroke.end.x),
                y: min(stroke.start.y, stroke.end.y),
                width: abs(stroke.end.x - stroke.start.x),
                height: abs(stroke.end.y - stroke.start.y)
            ))
        case .triangle:
            path.move(to: stroke.start)
            let midX = (stroke.start.x + stroke.end.x) / 2
            path.line(to: NSPoint(x: midX, y: stroke.end.y))
            path.line(to: stroke.end)
            path.close()
        case .arrow:
            path.move(to: stroke.start)
            path.line(to: stroke.end)
            let angle = atan2(stroke.end.y - stroke.start.y, stroke.end.x - stroke.start.x)
            let head: CGFloat = 14
            for sign: CGFloat in [1, -1] {
                let a = angle + sign * CGFloat.pi * 3 / 4
                path.line(to: NSPoint(
                    x: stroke.end.x + head * cos(a),
                    y: stroke.end.y + head * sin(a)
                ))
                path.move(to: stroke.end)
            }
        }
        path.lineWidth = stroke.width
        stroke.color.setStroke()
        path.stroke()
    }
}
