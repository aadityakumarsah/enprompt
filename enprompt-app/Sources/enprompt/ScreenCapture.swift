import AppKit
import CoreGraphics

/// Captures a circled region of the screen as a PNG. Requires Screen
/// Recording permission (prompted automatically on first use).
enum ScreenCapture {

    /// True when enprompt may capture the screen.
    static var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    /// Prompts for Screen Recording permission (macOS shows a system dialog;
    /// the app must be restarted after granting for it to take effect).
    static func requestPermission() {
        if !isAuthorized {
            CGRequestScreenCaptureAccess()
        }
    }

    /// Captures `rect` (in CG coordinates: top-left origin, points) and
    /// returns PNG data, downscaled so very large regions stay reasonably
    /// small for the vision API. nil when capture fails or permission is off.
    static func capturePNG(rect: CGRect, maxDimension: CGFloat = 1600) -> Data? {
        guard isAuthorized else { return nil }
        guard rect.width > 0, rect.height > 0 else { return nil }

        guard let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

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
    static func captureFullScreenJPEG(maxDimension: CGFloat = 1280, quality: CGFloat = 0.8) -> Data? {
        guard isAuthorized else { return nil }
        guard let screen = NSScreen.main else { return nil }
        let bounds = screen.frame
        let cgRect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        guard let image = CGWindowListCreateImage(
            cgRect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else { return nil }

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
    static func captureFullScreenPNG(maxDimension: CGFloat = 1600) -> Data? {
        guard isAuthorized else { return nil }
        guard let screen = NSScreen.main else { return nil }
        let bounds = screen.frame
        // CG coordinates: top-left origin. Main screen top-left is 0,0.
        let cgRect = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        return capturePNG(rect: cgRect, maxDimension: maxDimension)
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