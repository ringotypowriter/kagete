import AppKit
import Darwin
import Foundation

/// Long-lived overlay helper. One per-user Unix socket, one NSApp with a
/// transparent borderless window. Auto-retires after `idleTimeout` seconds
/// of no messages.
@MainActor
final class OverlayDaemon {
    private let state = OverlayState()
    private var window: NSWindow?
    /// Initialized once during `bindSocket()` and read-only thereafter, so
    /// safe to read from the accept thread.
    private nonisolated(unsafe) var listenFd: Int32 = -1
    /// Monotonic sequence; bumped on each pulse/release so deferred callbacks
    /// can detect they've been superseded by newer activity.
    private var activitySeq: UInt64 = 0
    private var lastActivityAt: Date = Date()

    static func run() -> Never {
        // Detach from controlling terminal so we survive parent exit cleanly.
        _ = setsid()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)   // no dock icon, no menu bar

        let daemon = OverlayDaemon()
        daemon.start()

        app.run()
        exit(0)
    }

    func start() {
        // Install the overlay window first so even the first message renders fast.
        let (w, _) = OverlayWindow.install(state: state)
        self.window = w
        state.mode = .active
        state.label = "ready"

        guard bindSocket() else {
            fputs("kagete overlay daemon: could not bind socket\n", stderr)
            exit(1)
        }

        resetIdleTimer()
    }

    // MARK: - Socket

    private func bindSocket() -> Bool {
        let path = OverlayConfig.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd); return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: Int8.self, capacity: bytes.count) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = Int8(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRes = withUnsafePointer(to: &addr) { p -> Int32 in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, len) }
        }
        if bindRes != 0 { close(fd); return false }
        chmod(path, 0o600)

        if listen(fd, 8) != 0 { close(fd); return false }

        listenFd = fd

        // Dedicated thread: accept() blocks cleanly here. DispatchSource on
        // the main queue and `Task { @MainActor }` both fail to drain under
        // `NSApp.run()`, so we bypass Swift concurrency entirely for IPC.
        let captured = self
        let thread = Thread {
            while true {
                let clientFd = Darwin.accept(captured.listenFd, nil, nil)
                if clientFd < 0 { break }
                captured.acceptOne(clientFd: clientFd)
            }
        }
        thread.name = "kagete.overlay.accept"
        thread.start()
        return true
    }

    /// Runs on `socketQueue` (off-main). Accepts the pending connection, reads
    /// the one-shot message, then dispatches the handler back to the main actor.
    private nonisolated func acceptOne(clientFd: Int32) {
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let line = OverlayWire.readLine(fd: clientFd),
              let data = line.data(using: .utf8),
              let msg = OverlayWire.decode(data)
        else {
            close(clientFd)
            return
        }
        // Schedule the handler on the main runloop. CFRunLoop works reliably
        // under NSApp.run() where GCD main + Swift concurrency don't.
        let selfRef = self
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                selfRef.handle(msg, clientFd: clientFd)
            }
            close(clientFd)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }


    // MARK: - Message handling

    private func handle(_ msg: OverlayMessage, clientFd: Int32) {
        switch msg {
        case .pulse(let p):
            showPulse(p)
            resetIdleTimer()

        case .release(let label):
            showReleased(label: label)

        case .status:
            let reply = "\(state.mode) label=\(state.label) app=\(state.app ?? "-")\n"
            _ = reply.withCString { Darwin.write(clientFd, $0, strlen($0)) }

        case .stop:
            scheduleExit(after: 0)
        }
    }

    private func showPulse(_ p: OverlayMessage.PulsePayload) {
        activitySeq &+= 1
        lastActivityAt = Date()
        let seq = activitySeq

        state.app = p.app
        state.label = p.label
        state.mode = .pulse
        state.visible = true
        relinquishActivation()

        let selfRef = self
        Self.runOnMain(after: OverlayConfig.pulseDuration) {
            guard selfRef.activitySeq == seq else { return }
            selfRef.state.mode = .active
            selfRef.state.label = "waiting"
            selfRef.relinquishActivation()
        }
    }

    private func showReleased(label: String) {
        activitySeq &+= 1     // supersede any pending pulse resets
        state.mode = .released
        state.label = label.isEmpty ? "control returned" : label
        state.visible = true
        relinquishActivation()
        scheduleExit(after: OverlayConfig.releaseDuration)
    }

    /// Ensure the daemon app is never the active app. If we accidentally
    /// stole activation during a SwiftUI re-render, hand it back immediately.
    private func relinquishActivation() {
        if NSApp.isActive {
            NSApp.deactivate()
        }
    }

    // MARK: - Lifecycle

    /// Poll every second on a background queue; if we've been idle past the
    /// timeout, hop to main and show the release ceremony.
    private func resetIdleTimer() {
        let selfRef = self
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    if selfRef.state.mode == .released { return }   // already retiring
                    if Date().timeIntervalSince(selfRef.lastActivityAt) >= OverlayConfig.idleTimeout {
                        selfRef.showReleased(label: "control returned")
                    } else {
                        selfRef.resetIdleTimer()
                    }
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }

    private func scheduleExit(after delay: TimeInterval) {
        Self.runOnMain(after: delay) {
            unlink(OverlayConfig.socketPath)
            exit(0)
        }
    }

    /// Dispatch a closure onto the main CFRunLoop after `delay`. Works under
    /// `NSApp.run()` where GCD main + Swift concurrency don't.
    private static func runOnMain(after delay: TimeInterval, _ block: @escaping @MainActor @Sendable () -> Void) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated { block() }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
    }
}
