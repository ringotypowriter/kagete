import AppKit
import SwiftUI

/// Transparent floating panel pinned above the menu bar, visible on every
/// Space. Uses `NSPanel + .nonactivatingPanel + .transient` so the daemon
/// app never takes focus away from whatever the user is working in.
final class NotchWindow: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask _: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backing,
            defer: flag
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 8)
        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle,
            .transient,
        ]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum OverlayWindow {
    @MainActor
    static func install(state: OverlayState) -> (NSWindow, NSScreen) {
        let screen = NSScreen.builtinOrMain
        let stripHeight: CGFloat = 140

        let rect = NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - stripHeight,
            width: screen.frame.width,
            height: stripHeight
        )

        let window = NotchWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        let notchHeight = max(0, screen.safeAreaInsets.top)
        state.topPadding = notchHeight > 0 ? notchHeight + 2 : 28

        let host = NSHostingView(rootView: OverlayRoot(state: state))
        host.frame = window.contentView?.bounds ?? rect
        host.autoresizingMask = [.width, .height]
        window.contentView = host

        // Capture the user's frontmost app before showing the panel, then
        // restore it right after. `.nonactivatingPanel` alone isn't enough:
        // the daemon's NSApp briefly activates on first window display.
        let previouslyActive = NSWorkspace.shared.frontmostApplication
        window.orderFrontRegardless()
        previouslyActive?.activate()
        return (window, screen)
    }
}

extension NSScreen {
    /// Prefer the built-in display (where the notch lives); fall back to main.
    static var builtinOrMain: NSScreen {
        let screenNumberKey = NSDeviceDescriptionKey(rawValue: "NSScreenNumber")
        for s in NSScreen.screens {
            if let id = s.deviceDescription[screenNumberKey],
               let rid = (id as? NSNumber)?.uint32Value,
               CGDisplayIsBuiltin(rid) == 1
            {
                return s
            }
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
