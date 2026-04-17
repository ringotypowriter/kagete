import SwiftUI

@MainActor
final class OverlayState: ObservableObject {
    enum Mode: Equatable { case idle, pulse, active, released }

    @Published var mode: Mode = .active
    @Published var label: String = "kagete"
    @Published var app: String? = nil
    @Published var visible: Bool = true
    @Published var topPadding: CGFloat = 28
}

struct OverlayRoot: View {
    @ObservedObject var state: OverlayState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                OverlayPill(state: state)
                Spacer()
            }
            .padding(.top, state.topPadding)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

struct OverlayPill: View {
    @ObservedObject var state: OverlayState
    @State private var pulsePhase: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            iconView
                .frame(width: 14, height: 14)

            HStack(spacing: 4) {
                Text(OverlayConfig.brandLabel)
                    .foregroundColor(.white.opacity(0.6))
                if let app = state.app {
                    Text("·").foregroundColor(.white.opacity(0.3))
                    Text(app).foregroundColor(.white.opacity(0.85))
                }
                Text("·").foregroundColor(.white.opacity(0.3))
                Text(state.label).foregroundColor(.white)
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
                .overlay(
                    Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                )
        )
        .scaleEffect(pulsePhase && state.mode == .pulse ? 1.06 : 1.0)
        .animation(.easeOut(duration: 0.18), value: pulsePhase)
        .opacity(state.visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.22), value: state.visible)
        .onChange(of: state.mode) { _, new in
            if new == .pulse {
                pulsePhase = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                    pulsePhase = false
                }
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        switch state.mode {
        case .idle, .active:
            StatusDot(color: .orange)
        case .pulse:
            Image(systemName: iconName(for: state.label))
                .foregroundColor(.orange)
                .font(.system(size: 12, weight: .bold))
        case .released:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 12, weight: .bold))
        }
    }

    private func iconName(for label: String) -> String {
        switch label {
        case "click": return "cursorarrow.click.2"
        case "type": return "keyboard"
        case "key": return "command"
        case "scroll": return "arrow.up.arrow.down"
        case "drag": return "hand.draw"
        case "screenshot": return "camera.viewfinder"
        default: return "bolt.fill"
        }
    }
}

struct StatusDot: View {
    let color: Color
    @State private var breathe: Bool = false
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(breathe ? 0.45 : 1.0)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: breathe)
            .onAppear { breathe = true }
    }
}
