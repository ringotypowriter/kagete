import AppKit
import SwiftUI

@MainActor
final class PermissionGuideState: ObservableObject {
    struct Entry: Identifiable {
        let id: String
        let name: String
        let paneURL: URL
        var granted: Bool
    }

    @Published var entries: [Entry]
    let host: String

    init(accessibility: Bool, screenRecording: Bool) {
        self.host = Permissions.hostLabel
        self.entries = [
            Entry(
                id: "accessibility",
                name: "Accessibility",
                paneURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!,
                granted: accessibility),
            Entry(
                id: "screenRecording",
                name: "Screen Recording",
                paneURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!,
                granted: screenRecording),
        ]
    }

    func refresh() {
        entries[0].granted = Permissions.accessibility
        entries[1].granted = Permissions.screenRecording
    }

    var allGranted: Bool { entries.allSatisfy(\.granted) }
}

struct PermissionGuideView: View {
    @ObservedObject var state: PermissionGuideState
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            permissionList
            Divider()
            footer
        }
        .frame(width: 420)
        .background(.ultraThickMaterial)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("kagete needs permissions")
                .font(.system(size: 16, weight: .semibold))
            Text("Grant these to **\(state.host)**, not to kagete itself.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 20)
        .padding(.horizontal, 24)
    }

    private var permissionList: some View {
        VStack(spacing: 0) {
            ForEach(state.entries) { entry in
                PermissionRow(entry: entry)
                if entry.id != state.entries.last?.id {
                    Divider().padding(.leading, 52)
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Refresh") {
                state.refresh()
            }
            .buttonStyle(.bordered)

            Spacer()

            if state.allGranted {
                Label("All set", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.green)
                Spacer().frame(width: 12)
            }

            Button(state.allGranted ? "Done" : "Close") {
                onDone()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(state.allGranted ? .defaultAction : .cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}

struct PermissionRow: View {
    let entry: PermissionGuideState.Entry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(entry.granted ? .green : .red)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 13, weight: .medium))
                Text(entry.granted ? "Granted" : "Not granted")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !entry.granted {
                Button("Open Settings") {
                    NSWorkspace.shared.open(entry.paneURL)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }
}

enum PermissionGuide {
    @MainActor
    static func show(accessibility: Bool, screenRecording: Bool) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)

        let state = PermissionGuideState(
            accessibility: accessibility, screenRecording: screenRecording)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "kagete"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating

        let hosting = NSHostingView(rootView: PermissionGuideView(state: state) {
            app.stop(nil)
        })
        window.contentView = hosting
        window.makeKeyAndOrderFront(nil)

        app.run()
    }
}
