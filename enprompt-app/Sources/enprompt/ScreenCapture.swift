import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Captures a circled region of the screen as a PNG. Requires Screen
/// Recording permission.
///
/// Uses ScreenCaptureKit (macOS 14+): macOS only shows the automatic one-click
/// "Allow" screen-recording prompt when an app uses SCK - the legacy
/// CGWindowListCreateImage API never prompts and forces users to add the app
/// manually via System Settings → Privacy → Screen Recording (+ button).
enum ScreenCapture {

    /// True when enprompt may capture the screen.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Triggers the macOS screen-recording permission prompt. While
    /// unauthorized, attempting to enumerate shareable content via
    /// ScreenCaptureKit makes the system show the standard "enprompt would
    /// like to record this Mac's screen" alert - one click on Allow, no
    /// System Settings needed.
    static func requestPermission() async {
        guard !isAuthorized else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first else { return }
        // A minimal capture attempt guarantees the prompt is shown (the
        // enumeration alone can be enough, but this is deterministic).
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = 1
        config.height = 1
        _ = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// Captures `rect` (in CG coordinates: top-left origin, points) and
    /// returns PNG data, downscaled so very large regions stay reasonably
    /// small for the vision API. nil when capture fails or permission is off.
    static func capturePNG(rect: CGRect, maxDimension: CGFloat = 1600) async -> Data? {
        guard isAuthorized else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }
        guard let image = await displayImage(croppedTo: rect) else { return nil }

        var finalImage = image
        let longest = max(image.width, image.height)
        if longest > Int(maxDimension) {
            let scale = maxDimension / CGFloat(longest)
            let newSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            if let resized = resize(image, to: newSize) {
                finalImage = resized
            }
        }

        let rep = NSBitmapImageRep(cgImage: finalImage)
        return rep.representation(using: .png, properties: [:])
    }

    /// Captures the whole main screen as JPEG (much smaller than PNG - faster
    /// uploads and vision processing).
    static func captureFullScreenJPEG(maxDimension: CGFloat = 1280, quality: CGFloat = 0.8) async -> Data? {
        guard isAuthorized else { return nil }
        guard let screen = NSScreen.main else { return nil }
        let cgRect = cgRect(for: screen)
        guard let image = await displayImage(croppedTo: cgRect) else { return nil }

        var finalImage = image
        let longest = max(image.width, image.height)
        if longest > Int(maxDimension) {
            let scale = maxDimension / CGFloat(longest)
            let newSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
            if let resized = resize(image, to: newSize) {
                finalImage = resized
            }
        }

        let rep = NSBitmapImageRep(cgImage: finalImage)
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    /// Captures the whole main screen and returns PNG data (downscaled).
    static func captureFullScreenPNG(maxDimension: CGFloat = 1600) async -> Data? {
        guard isAuthorized else { return nil }
        guard let screen = NSScreen.main else { return nil }
        return await capturePNG(rect: cgRect(for: screen), maxDimension: maxDimension)
    }

    /// Captures the display containing `rect` via ScreenCaptureKit and crops
    /// the image down to `rect` (CG coordinates: top-left origin, points).
    private static func displayImage(croppedTo rect: CGRect) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else {
            return nil
        }
        let screen = NSScreen.screens.first { screen in
            let frame = cgRect(for: screen)
            return frame.contains(rect.origin) && frame.contains(CGPoint(x: rect.maxX, y: rect.maxY))
        } ?? NSScreen.main
        guard let screen else { return nil }

        let screenID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        let display = content.displays.first { $0.displayID == screenID?.uint32Value }
            ?? content.displays.first
        guard let display else { return nil }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        // Default configuration captures the display at its native resolution.
        let config = SCStreamConfiguration()
        guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else {
            return nil
        }

        // Crop: rect is in CG points (top-left origin); the capture is in
        // pixels on the display, so scale by the image's pixel density.
        let scale = CGFloat(image.width) / display.frame.width
        let origin = display.frame.origin
        let crop = CGRect(
            x: (rect.minX - origin.x) * scale,
            y: (rect.minY - origin.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
        return image.cropping(to: crop.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)))
    }

    /// Draws the user's canvas annotations (strokes in view coordinates with
    /// bottom-left origin, 1pt = 1 screen point) on top of the screenshot.
    static func composite(
        strokes: [CanvasStroke],
        screenSize: CGSize,
        onto image: CGImage
    ) -> CGImage {
        guard !strokes.isEmpty else { return image }
        let scale = CGFloat(image.width) / screenSize.width
        guard let ctx = CGContext(
            data: nil,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)

        func cgPoint(_ p: CGPoint) -> CGPoint {
            // Flip Y (view bottom-left → CG top-left) and scale to pixels.
            CGPoint(x: p.x * scale, y: (screenSize.height - p.y) * scale)
        }

        for stroke in strokes {
            guard stroke.expiresAt.map({ $0 > CFAbsoluteTimeGetCurrent() }) ?? true else { continue }
            ctx.setStrokeColor(stroke.color.withAlphaComponent(0.95).cgColor)
            ctx.setLineWidth(stroke.width * scale)
            let path = CGMutablePath()
            switch stroke.shape {
            case .pen:
                guard let first = stroke.points.first else { continue }
                path.move(to: cgPoint(first))
                for point in stroke.points.dropFirst() {
                    path.addLine(to: cgPoint(point))
                }
            case .rect:
                let s = cgPoint(stroke.start)
                let e = cgPoint(stroke.end)
                path.addRect(CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y)))
            case .ellipse:
                let s = cgPoint(stroke.start)
                let e = cgPoint(stroke.end)
                path.addEllipse(in: CGRect(x: min(s.x, e.x), y: min(s.y, e.y), width: abs(e.x - s.x), height: abs(e.y - s.y)))
            case .triangle:
                let s = cgPoint(stroke.start)
                let e = cgPoint(stroke.end)
                path.move(to: s)
                path.addLine(to: CGPoint(x: (s.x + e.x) / 2, y: e.y))
                path.addLine(to: e)
                path.closeSubpath()
            case .arrow:
                let s = cgPoint(stroke.start)
                let e = cgPoint(stroke.end)
                path.move(to: s)
                path.addLine(to: e)
                let angle = atan2(e.y - s.y, e.x - s.x)
                let head: CGFloat = 14 * scale
                for sign: CGFloat in [1, -1] {
                    let a = angle + sign * CGFloat.pi * 3 / 4
                    path.move(to: e)
                    path.addLine(to: CGPoint(x: e.x + head * cos(a), y: e.y + head * sin(a)))
                }
            }
            ctx.addPath(path)
            ctx.strokePath()
        }
        return ctx.makeImage() ?? image
    }

    /// Converts an AppKit screen frame (bottom-left origin, global point
    /// space) into CG coordinates (top-left origin on the primary display).
    private static func cgRect(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height ?? frame.height
        return CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let ctx = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        return ctx.makeImage()
    }
}