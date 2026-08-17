import AppKit
import Foundation

/// Full-screen "on-screen teaching" overlay: while the explanation is spoken,
/// it floats above everything (click-through, so typing keeps working),
/// showing the text with the word currently being spoken highlighted, and a
/// soft glow around the selected text being explained. Press Esc to dismiss.
@MainActor
final class TeachOverlayController {

    private var window: NSWindow?
    private weak var overlayView: TeachOverlayView?
    private var escMonitor: Any?

    var isVisible: Bool { window != nil }

    /// Shows the overlay with the explanation text and (optionally) the
    /// screen frame of the selected text, which gets a glow box.
    func show(text: String, highlightRect: CGRect?) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.frame
        if let window, let view = overlayView {
            view.set(text: text, highlightRect: highlightRect, frame: frame)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = TeachOverlayWindow(
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
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        let view = TeachOverlayView(frame: frame)
        view.set(text: text, highlightRect: highlightRect, frame: frame)
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        self.window = window
        overlayView = view
        installEscMonitor()
    }

    /// Highlights the word at this character range (Apple voices give the
    /// exact range about to be spoken).
    func update(range: NSRange) {
        overlayView?.highlight(range: range)
    }

    /// Highlights the word at this fraction of the text (neural/Piper voices,
    /// estimated from playback position).
    func update(fraction: Double, textLength: Int) {
        overlayView?.highlight(fraction: fraction, textLength: textLength)
    }

    func hide() {
        removeEscMonitor()
        window?.orderOut(nil)
        window = nil
        overlayView = nil
    }

    private func installEscMonitor() {
        guard escMonitor == nil else { return }
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Esc
                self?.hide()
                return nil
            }
            return event
        }
    }

    private func removeEscMonitor() {
        if let escMonitor {
            NSEvent.removeMonitor(escMonitor)
            self.escMonitor = nil
        }
    }
}

@MainActor
private final class TeachOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Renders the caption + selection glow. The caption stays near the top of
/// the screen; the word being spoken is drawn bigger and in orange.
@MainActor
private final class TeachOverlayView: NSView {

    private var text: NSString = ""
    private var wordBoundaries: [NSRange] = []
    private var highlightRange: NSRange?
    private var highlightRect: CGRect?

    /// The 1-2 sentences currently shown in the caption area.
    private var captionLine: NSString = ""
    private var captionHighlight: NSRange?

    func set(text: String, highlightRect: CGRect?, frame: NSRect) {
        self.text = text as NSString
        // Only glow when the selection is actually visible on this screen;
        // a rect on another display (or stale) would float in the middle of
        // nowhere and break the whole illusion.
        if let highlightRect {
            let clipped = highlightRect.intersection(frame)
            self.highlightRect = clipped.width > 8 && clipped.height > 8 ? clipped : nil
        } else {
            self.highlightRect = nil
        }
        wordBoundaries = Self.wordRanges(in: self.text)
        highlightRange = nil
        updateCaption(lineForFraction: 0)
        needsDisplay = true
    }

    /// The character index (UTF-16) of the current word, given the playback
    /// fraction. Used by the neural/Piper engines that don't report ranges.
    private func wordIndex(atFraction fraction: Double) -> Int {
        let target = Int(Double(text.length) * min(max(fraction, 0), 1))
        if let range = wordBoundaries.first(where: { target >= $0.location && target <= $0.location + $0.length }) {
            return range.location
        }
        if let index = wordBoundaries.firstIndex(where: { $0.location >= target }) {
            return wordBoundaries[index].location
        }
        return 0
    }

    func highlight(range: NSRange) {
        guard range.location != NSNotFound, range.length > 0,
              range.location >= 0, range.location + range.length <= text.length,
              text.length > 0 else { return }
        highlightRange = range
        updateCaption(for: range)
        needsDisplay = true
    }

    func highlight(fraction: Double, textLength: Int) {
        guard textLength > 0 else { return }
        let index = wordIndex(atFraction: fraction)
        highlight(range: NSRange(location: index, length: 1))
    }

    /// Picks the sentence (up to a few lines) containing the highlighted word
    /// so the caption always shows the current context, not the whole text.
    private func updateCaption(for range: NSRange) {
        let sentenceRange = Self.sentenceRange(in: text, containing: range.location)
        let local = NSRange(
            location: min(max(range.location - sentenceRange.location, 0), max(sentenceRange.length - 1, 0)),
            length: min(max(range.length, 1), max(sentenceRange.length, 1))
        )
        captionLine = text.substring(with: sentenceRange) as NSString
        captionHighlight = NSRange(
            location: local.location,
            length: min(local.length, max(sentenceRange.length - local.location, 1))
        )
        needsDisplay = true
    }

    private func updateCaption(lineForFraction fraction: Double) {
        let index = wordIndex(atFraction: fraction)
        let sentenceRange = Self.sentenceRange(in: text, containing: index)
        captionLine = text.substring(with: sentenceRange) as NSString
        captionHighlight = NSRange(location: index - sentenceRange.location, length: 1)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        // Glow around the selected text being explained.
        if let highlightRect {
            let box = NSRect(
                x: highlightRect.minX - 8,
                y: bounds.height - highlightRect.maxY - 8,
                width: highlightRect.width + 16,
                height: highlightRect.height + 16
            )
            let path = NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10)
            NSColor.systemOrange.withAlphaComponent(0.10).setFill()
            path.fill()
            NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
            path.lineWidth = 3
            path.stroke()
        }

        guard captionLine.length > 0 else { return }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 6
        paragraph.alignment = .center

        let normal: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: paragraph,
        ]
        let highlighted: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 38, weight: .heavy),
            .foregroundColor: NSColor.systemOrange,
            .paragraphStyle: paragraph,
        ]

        let attributed = NSMutableAttributedString(string: captionLine as String, attributes: normal)
        if let captionHighlight,
           captionHighlight.location + captionHighlight.length <= captionLine.length {
            attributed.addAttributes(highlighted, range: captionHighlight)
        }

        let maxWidth = bounds.width * 0.7
        let textHeight = 150.0
        let captionRect = NSRect(
            x: (bounds.width - maxWidth) / 2,
            y: bounds.height - textHeight - 40,
            width: maxWidth,
            height: textHeight
        )
        attributed.draw(with: captionRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    /// Word ranges (UTF-16) split on whitespace, including trailing
    /// punctuation so the highlight covers the whole token.
    private static func wordRanges(in text: NSString) -> [NSRange] {
        var ranges: [NSRange] = []
        var current = NSRange(location: 0, length: 0)
        var scanning = false
        let charset = CharacterSet.whitespacesAndNewlines
        for i in 0..<text.length {
            let scalar = text.substring(with: NSRange(location: i, length: 1))
            let isSpace = scalar.rangeOfCharacter(from: charset) != nil
            if !isSpace && !scanning {
                scanning = true
                current = NSRange(location: i, length: 1)
            } else if !isSpace && scanning {
                current.length += 1
            } else if isSpace && scanning {
                ranges.append(current)
                scanning = false
            }
        }
        if scanning { ranges.append(current) }
        return ranges
    }

    /// The sentence (bounded by . ! ? or newline, with a little lookahead)
    /// containing the given character index.
    private static func sentenceRange(in text: NSString, containing index: Int) -> NSRange {
        guard text.length > 0 else { return NSRange(location: 0, length: 0) }
        let bound = max(0, min(index, text.length - 1))
        var start = 0
        var end = text.length
        let separators = CharacterSet(charactersIn: ".\n!?।")
        for i in stride(from: bound, to: 0, by: -1) {
            let scalar = text.substring(with: NSRange(location: i, length: 1))
            if scalar.rangeOfCharacter(from: separators) != nil {
                start = i + 1
                break
            }
        }
        for i in bound..<text.length {
            let scalar = text.substring(with: NSRange(location: i, length: 1))
            if scalar.rangeOfCharacter(from: separators) != nil {
                end = i + 1
                break
            }
        }
        // Skip a leading space when the sentence starts mid-text.
        let range = NSRange(location: start, length: max(end - start, 1))
        if text.substring(with: range).hasPrefix(" ") {
            return NSRange(location: start + 1, length: max(end - start - 1, 1))
        }
        return range
    }
}
