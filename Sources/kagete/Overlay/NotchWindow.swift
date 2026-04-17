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
    private static let stripHeight: CGFloat = 140

    @MainActor
    static func install(state: OverlayState) -> NSWindow {
        let screen = NSScreen.cursorScreen
        let rect = stripRect(for: screen)

        let window = NotchWindow(
            contentRect: rect,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false,
            screen: screen
        )

        applyPadding(for: screen, state: state)

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
        return window
    }

    /// Move the window to the screen currently containing the cursor. No-op
    /// if it's already there. Called before each pulse so the pill appears
    /// on whichever monitor the user is working on.
    @MainActor
    static func followCursor(_ window: NSWindow, state: OverlayState) {
        let screen = NSScreen.cursorScreen
        if window.screen == screen { return }
        window.setFrame(stripRect(for: screen), display: false)
        applyPadding(for: screen, state: state)
    }

    private static func stripRect(for screen: NSScreen) -> NSRect {
        NSRect(
            x: screen.frame.origin.x,
            y: screen.frame.origin.y + screen.frame.height - stripHeight,
            width: screen.frame.width,
            height: stripHeight
        )
    }

    @MainActor
    private static func applyPadding(for screen: NSScreen, state: OverlayState) {
        let notchHeight = max(0, screen.safeAreaInsets.top)
        state.topPadding = notchHeight > 0 ? notchHeight + 2 : 28
    }
}

extension NSScreen {
    /// The screen currently containing the mouse cursor. Falls back to `main`
    /// and then to the first screen if the cursor is somehow outside every
    /// screen frame (shouldn't happen but defensive).
    static var cursorScreen: NSScreen {
        let p = NSEvent.mouseLocation
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            return hit
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }
}
