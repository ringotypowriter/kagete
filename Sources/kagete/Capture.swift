import AppKit
import CoreGraphics
import CoreText
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    static func screenshot(
        pid: pid_t, windowFilter: String?, output: URL,
        grid: Bool = false, gridPitch: CGFloat = 200,
        captureScale: CGFloat = 0.5,
        crop: CGRect? = nil
    ) async throws {
        guard Permissions.screenRecording else {
            throw KageteError.notTrusted(
                "Screen Recording permission not granted. Run `kagete doctor --prompt` or grant it in System Settings → Privacy & Security → Screen Recording.")
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
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

        // Downsample for agent consumption. Default captureScale=0.5 produces
        // roughly half-dimension PNGs (~0.6 MB vs ~2.5 MB for a 2320-point
        // window) while keeping grid labels legible. `--scale 1` restores
        // full screen-point fidelity.
        let scale = max(0.1, captureScale)
        let config = SCStreamConfiguration()
        config.width = max(1, Int(target.frame.width * scale))
        config.height = max(1, Int(target.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: target)
        var cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

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

        if grid {
            // Core Text + CGContext bitmap drawing needs the CGS session to
            // be initialized. Hopping to the main actor is the simplest way
            // to trigger that from a plain async CLI.
            let annotated = await MainActor.run { () -> CGImage? in
                overlayGrid(
                    on: cgImage,
                    windowOrigin: effectiveOrigin,
                    scale: scale,
                    pitch: gridPitch)
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
        on image: CGImage, windowOrigin: CGPoint, scale: CGFloat, pitch: CGFloat
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

        // Fixed pixel dimensions (independent of capture scale) keep labels
        // readable at both 0.5x and 1x captures.
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
