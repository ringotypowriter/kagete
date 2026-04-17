import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit
import UniformTypeIdentifiers

enum Capture {
    static func screenshot(pid: pid_t, windowFilter: String?, output: URL) async throws {
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

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let config = SCStreamConfiguration()
        config.width = max(1, Int(target.frame.width * scale))
        config.height = max(1, Int(target.frame.height * scale))
        config.showsCursor = false
        config.capturesAudio = false

        let filter = SCContentFilter(desktopIndependentWindow: target)
        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)

        try writePNG(cgImage, to: output)
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
