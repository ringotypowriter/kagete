import AppKit
import CoreGraphics
import CoreText
import Foundation
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    static func screenshot(
        pid: pid_t, windowFilter: String?, output: URL,
        grid: Bool = false, gridPitch: CGFloat = 200,
        captureScale: CGFloat = 0.8,
        crop: CGRect? = nil
    ) async throws {
        guard Permissions.screenRecording else {
            throw KageteError.notTrusted(
                "Screen Recording permission not granted. Run `kagete doctor --prompt`, or grant it to \"\(Permissions.hostLabel)\" (the process that launched kagete — not kagete itself) in System Settings → Privacy & Security → Screen Recording.")
        }

        let content = try await withSCKTimeout(seconds: 10, label: "SCShareableContent") {
            try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        }
        let candidates = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        }
        guard !candidates.isEmpty else {
            throw KageteError.notFound("No capturable windows for pid \(pid).")
        }

        let target: SCWindow
        if let filter = windowFilter {
            guard let hit = candidates.first(where: {
                ($0.title ?? "").localizedCaseInsensitiveContains(filter)
            }) else {
                let titles = candidates.map { $0.title ?? "(untitled)" }.joined(separator: ", ")
                throw KageteError.notFound("No window matching \"\(filter)\" for pid \(pid). Available: \(titles)")
            }
            target = hit
        } else {
            target = candidates[0]
        }

        // Downsample for agent consumption. Default captureScale=0.8 keeps
        // enough pixel density for agents to read small UI text and fine
        // details while still trimming PNG size vs native 1.0. Earlier
        // 0.5 default was too soft — agents lost legibility on icons and
        // mid-weight Chinese / dense CJK glyphs.
        let scale = max(0.1, captureScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(target.frame.width * scale))
        config.height = max(1, Int(target.frame.height * scale))
        config.showsCursor = true
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: target)
        var cgImage = try await withSCKTimeout(seconds: 15, label: "SCScreenshotManager.captureImage") {
            try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        }

        // Crop is expressed in window-relative screen points. Convert to
        // image-pixel rect (y=0 at top, same as window) and crop the captured
        // CGImage. Labels below shift `windowOrigin` by the crop offset so the
        // grid keeps showing absolute screen coords.
        var effectiveOrigin = target.frame.origin
        if let crop = crop {
            let pxCrop = CGRect(
                x: max(0, crop.origin.x * scale),
                y: max(0, crop.origin.y * scale),
                width: min(CGFloat(cgImage.width) - crop.origin.x * scale, crop.width * scale),
                height: min(CGFloat(cgImage.height) - crop.origin.y * scale, crop.height * scale))
            if pxCrop.width > 0, pxCrop.height > 0,
               let cropped = cgImage.cropping(to: pxCrop)
            {
                cgImage = cropped
                effectiveOrigin = CGPoint(
                    x: target.frame.origin.x + crop.origin.x,
                    y: target.frame.origin.y + crop.origin.y)
            }
        }

        // Focus indicator — blinking caret in screenshots is unreliable
        // signal for "is this input actually focused", so we look it up
        // via AX and draw a rect over the element's frame.
        let focusInfo: (role: String?, frame: CGRect)? = {
            guard let snap = AXInspector.focusedSnapshot(pid: pid),
                  let frame = snap.frame,
                  frame.width > 0, frame.height > 0
            else { return nil }
            return (snap.role, frame)
        }()

        if grid {
            // Core Text + CGContext bitmap drawing needs the CGS session to
            // be initialized. Hopping to the main actor is the simplest way
            // to trigger that from a plain async CLI.
            let annotated = await MainActor.run { () -> CGImage? in
                overlayGrid(
                    on: cgImage,
                    windowOrigin: effectiveOrigin,
                    scale: scale,
                    pitch: gridPitch,
                    focusFrame: focusInfo?.frame,
                    focusRole: focusInfo?.role)
            }
            if let annotated { cgImage = annotated }
        }

        try writePNG(cgImage, to: output)
    }

    /// Overlay screen-point gridlines on a captured window image. Labels show
    /// the absolute screen-point coordinate that the line corresponds to —
    /// matching the coordinate system used by `kagete click --x --y`.
    ///
    /// Coordinate convention: CGContext native origin is bottom-left (y-up).
    /// Screen / window coords are top-down (y-down). We draw everything in
    /// the native y-up system and convert screen-y -> ctx-y with
    /// `ctxY = pxH - screenY * pxPerPt`.
    private static func overlayGrid(
        on image: CGImage, windowOrigin: CGPoint, scale: CGFloat, pitch: CGFloat,
        focusFrame: CGRect? = nil, focusRole: String? = nil
    ) -> CGImage? {
        let pxW = image.width, pxH = image.height
        let h = CGFloat(pxH)
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        // CGContext.draw places image such that it appears right-side-up in
        // the default y-up coordinate system. No flip needed here.
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: pxW, height: pxH))

        let pxPerPt = scale
        let viewW = CGFloat(pxW) / pxPerPt
        let viewH = CGFloat(pxH) / pxPerPt

        // Minor subdivision lines — half-pitch step, drawn first (below the
        // major lines) so majors stay visually dominant. Unlabeled, faint
        // stroke — gives the agent finer reference anchors between labels
        // without cluttering readable text.
        let minorPitch = pitch / 2
        ctx.setStrokeColor(CGColor(red: 0.98, green: 0.2, blue: 0.2, alpha: 0.16))
        ctx.setLineWidth(1)
        var mnx = ceil(windowOrigin.x / minorPitch) * minorPitch
        while mnx <= windowOrigin.x + viewW {
            // Skip exact-pitch lines — the major loop below handles those.
            if mnx.truncatingRemainder(dividingBy: pitch) != 0 {
                let imgX = (mnx - windowOrigin.x) * pxPerPt
                ctx.move(to: CGPoint(x: imgX, y: 0))
                ctx.addLine(to: CGPoint(x: imgX, y: h))
            }
            mnx += minorPitch
        }
        var mny = ceil(windowOrigin.y / minorPitch) * minorPitch
        while mny <= windowOrigin.y + viewH {
            if mny.truncatingRemainder(dividingBy: pitch) != 0 {
                let screenRelY = (mny - windowOrigin.y) * pxPerPt
                let imgY = h - screenRelY
                ctx.move(to: CGPoint(x: 0, y: imgY))
                ctx.addLine(to: CGPoint(x: CGFloat(pxW), y: imgY))
            }
            mny += minorPitch
        }
        ctx.strokePath()

        // Major grid lines (labeled below). Slightly more opaque than minors
        // so the labeled anchors stand out.
        ctx.setStrokeColor(CGColor(red: 0.98, green: 0.2, blue: 0.2, alpha: 0.42))
        ctx.setLineWidth(1.5)

        // Vertical lines (run full height)
        var gx = ceil(windowOrigin.x / pitch) * pitch
        while gx <= windowOrigin.x + viewW {
            let imgX = (gx - windowOrigin.x) * pxPerPt
            ctx.move(to: CGPoint(x: imgX, y: 0))
            ctx.addLine(to: CGPoint(x: imgX, y: h))
            gx += pitch
        }
        // Horizontal lines — screen y converts to y-up ctx coord
        var gy = ceil(windowOrigin.y / pitch) * pitch
        while gy <= windowOrigin.y + viewH {
            let screenRelY = (gy - windowOrigin.y) * pxPerPt
            let imgY = h - screenRelY
            ctx.move(to: CGPoint(x: 0, y: imgY))
            ctx.addLine(to: CGPoint(x: CGFloat(pxW), y: imgY))
            gy += pitch
        }
        ctx.strokePath()

        // Focus indicator — screen-point-space rect of the currently-focused
        // AX element. Blinking text carets are mid-blink half the time in a
        // screenshot, so the agent can't tell from the image alone whether
        // an input is focused. Drawing a bright green border + role tag
        // around the focused element's frame gives unambiguous ground truth.
        if let frame = focusFrame {
            let relX = (frame.origin.x - windowOrigin.x) * pxPerPt
            let relYTop = (frame.origin.y - windowOrigin.y) * pxPerPt
            let w = frame.width * pxPerPt
            let fh = frame.height * pxPerPt
            let ctxY = h - relYTop - fh
            let rect = CGRect(x: relX, y: ctxY, width: w, height: fh)
            // Outer halo + inner bright stroke for contrast on any background.
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.85))
            ctx.setLineWidth(4)
            ctx.stroke(rect)
            ctx.setStrokeColor(CGColor(red: 0.15, green: 0.75, blue: 0.35, alpha: 1.0))
            ctx.setLineWidth(2.5)
            ctx.stroke(rect)

            let tagText = "focus: \(focusRole ?? "?")"
            let tagFont = CTFontCreateWithName("Menlo" as CFString, 12, nil)
            let tagAttrs: [NSAttributedString.Key: Any] = [
                .font: tagFont,
                .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1),
            ]
            let tagBg = CGColor(red: 0.12, green: 0.6, blue: 0.28, alpha: 0.95)
            // Place tag just above the rect in screen-top-down coords.
            drawLabelYUp(
                tagText, nearX: relX,
                screenTopY: (relYTop - 18) / pxPerPt,
                pxH: h, pxPerPt: pxPerPt,
                attrs: tagAttrs, bg: tagBg, in: ctx)
        }

        // Cursor indicator — draws a crosshair where the cursor currently is
        // (in-window) so the agent can see exactly where its last click
        // landed. When the cursor is outside the captured region, we still
        // draw a corner badge with its coords so the agent is never in the
        // dark about the actual click target.
        let cursor = CGEvent(source: nil)?.location ?? .zero
        let cursorRelX = (cursor.x - windowOrigin.x) * pxPerPt
        let cursorRelY = (cursor.y - windowOrigin.y) * pxPerPt
        let cursorInside =
            cursorRelX >= 0 && cursorRelX <= CGFloat(pxW)
            && cursorRelY >= 0 && cursorRelY <= CGFloat(pxH)
        if cursorInside {
            let cx = cursorRelX
            let cy = h - cursorRelY
            let r: CGFloat = 14
            ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.9))
            ctx.setLineWidth(3)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.setStrokeColor(CGColor(red: 1.0, green: 0.0, blue: 0.5, alpha: 1.0))
            ctx.setLineWidth(2)
            ctx.strokeEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.move(to: CGPoint(x: cx - r - 6, y: cy))
            ctx.addLine(to: CGPoint(x: cx + r + 6, y: cy))
            ctx.move(to: CGPoint(x: cx, y: cy - r - 6))
            ctx.addLine(to: CGPoint(x: cx, y: cy + r + 6))
            ctx.strokePath()
        }

        // Label sizing — scale font down when cells are tight so
        // neighbouring labels don't overrun each other. A cell roughly
        // `pitch*pxPerPt` wide needs to fit a ~5-char label like "x=2200".
        let cellPx = pitch * pxPerPt
        let fontSize = max(9, min(14, cellPx / 5))
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 0.9, green: 0.12, blue: 0.12, alpha: 1.0),
        ]
        let bg = CGColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.82)

        // X labels along the top. Row is ~ (fontSize + 6) tall, record it so
        // Y labels can start below it without overlapping.
        let xRowHeight = fontSize + 6
        gx = ceil(windowOrigin.x / pitch) * pitch
        while gx <= windowOrigin.x + viewW {
            let imgX = (gx - windowOrigin.x) * pxPerPt
            drawLabelYUp(
                "x=\(Int(gx))", nearX: imgX + 3, screenTopY: 3,
                pxH: h, pxPerPt: pxPerPt,
                attrs: attrs, bg: bg, in: ctx)
            gx += pitch
        }

        // Y labels along the left. Skip any that would land inside the
        // X-label row (top-left collision), and nudge each label just below
        // the gridline it belongs to.
        gy = ceil(windowOrigin.y / pitch) * pitch
        while gy <= windowOrigin.y + viewH {
            let screenRelY = (gy - windowOrigin.y) * pxPerPt
            if screenRelY >= xRowHeight {
                drawLabelYUp(
                    "y=\(Int(gy))", nearX: 4, screenTopY: screenRelY / pxPerPt + 3,
                    pxH: h, pxPerPt: pxPerPt,
                    attrs: attrs, bg: bg, in: ctx)
            }
            gy += pitch
        }

        // Cursor coords badge — bottom-right corner. Shows the current
        // system cursor location regardless of whether it's inside the
        // captured region, so the agent always has ground truth about where
        // its last click actually landed.
        let badgeText = cursorInside
            ? "cursor: (\(Int(cursor.x)), \(Int(cursor.y)))"
            : "cursor: (\(Int(cursor.x)), \(Int(cursor.y))) — off-window"
        let badgeFont = CTFontCreateWithName("Menlo" as CFString, 12, nil)
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: badgeFont,
            .foregroundColor: CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1.0),
        ]
        let badgeBg = CGColor(
            red: cursorInside ? 1.0 : 1.0,
            green: cursorInside ? 0.82 : 0.95,
            blue: cursorInside ? 0.22 : 0.4,
            alpha: 0.92)
        let attributedBadge = NSAttributedString(string: " \(badgeText) ", attributes: badgeAttrs)
        let badgeLine = CTLineCreateWithAttributedString(attributedBadge)
        let badgeBounds = CTLineGetBoundsWithOptions(badgeLine, [.useOpticalBounds])
        let badgeTopY = CGFloat(pxH) - badgeBounds.height - 10
        drawLabelYUp(
            badgeText,
            nearX: CGFloat(pxW) - badgeBounds.width - 10,
            screenTopY: badgeTopY / pxPerPt,
            pxH: h, pxPerPt: pxPerPt,
            attrs: badgeAttrs, bg: badgeBg, in: ctx)

        return ctx.makeImage()
    }

    /// Draw a label at (nearX, screenTopY) where screenTopY is in screen-point
    /// top-down space relative to the window. Converts to the context's y-up
    /// coordinate and paints a translucent background rect behind the glyphs.
    private static func drawLabelYUp(
        _ text: String, nearX: CGFloat, screenTopY: CGFloat,
        pxH: CGFloat, pxPerPt: CGFloat,
        attrs: [NSAttributedString.Key: Any], bg: CGColor, in ctx: CGContext
    ) {
        let attributed = NSAttributedString(string: " \(text) ", attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        let b = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])

        let screenTopPx = screenTopY * pxPerPt
        // In y-up coords, label "top-left" is higher than "baseline-left".
        let baselineY = pxH - screenTopPx - b.height - b.origin.y

        let bgRect = CGRect(
            x: nearX - 1,
            y: pxH - screenTopPx - b.height - 2,
            width: b.width + 2,
            height: b.height + 4)
        ctx.saveGState()
        ctx.setFillColor(bg)
        ctx.fill(bgRect)
        ctx.textPosition = CGPoint(x: nearX, y: baselineY)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// Race an async ScreenCaptureKit call against a timeout. Apple's SCK
    /// bridge can leak its checked continuation (prints "SWIFT TASK
    /// CONTINUATION MISUSE") and never resume, wedging the process forever.
    /// Converting the wedge into a surfaced error lets callers retry or fall
    /// back instead of hanging an E2E run.
    private static func withSCKTimeout<T: Sendable>(
        seconds: Double, label: String, _ op: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw KageteError.failure(
                    "\(label) timed out after \(Int(seconds))s — ScreenCaptureKit did not respond. Retry, or check if the target window is minimized / off-screen.")
            }
            guard let first = try await group.next() else {
                throw KageteError.failure("\(label) produced no result.")
            }
            group.cancelAll()
            return first
        }
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else {
            throw KageteError.failure("Failed to create image destination at \(url.path).")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw KageteError.failure("Failed to write PNG to \(url.path).")
        }
    }
}
