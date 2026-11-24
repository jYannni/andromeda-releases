import SwiftUI

struct StartScanButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            StartScanLabel()
        }
        .buttonStyle(StartScanButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

private struct StartScanLabel: View {
    var body: some View {
        Label {
            Text(UICopy.scanMyMac)
        } icon: {
            Image(systemName: "viewfinder")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ScanColors.lavender)
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white)
    }
}

private enum ScanColors {
    // The Display P3 gradient and lavender spiral arms from AppIcon.icon.
    static let blue = Color(.displayP3, red: 0.30980, green: 0.61961, blue: 1)
    static let purple = Color(.displayP3, red: 0.33442, green: 0.30051, blue: 0.58663)
    static let lavender = Color(.sRGB, red: 229 / 255, green: 223 / 255, blue: 1)
}

private struct ScanButtonSurface: View {
    let shape: RoundedRectangle
    var pressed = false

    var body: some View {
        shape.fill(LinearGradient(
            colors: [ScanColors.blue, ScanColors.purple], startPoint: .topLeading, endPoint: .bottomTrailing
        ))
        // Shade the bright blue for contrast with the label and symbol.
        .overlay { shape.fill(.black.opacity(0.24)) }
        .shadow(color: ScanColors.purple.opacity(pressed ? 0.16 : 0.30),
                radius: pressed ? 2 : 5, y: pressed ? 1 : 3)
        .overlay { shape.strokeBorder(ScanColors.lavender.opacity(pressed ? 0.8 : 0.38)) }
    }
}

private struct StartScanButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)

        configuration.label
            .padding(.horizontal, 16)
            .frame(minHeight: 48)
            .background {
                ScanButtonSurface(shape: shape, pressed: configuration.isPressed)
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.55)
    }
}

/// A single surface travels between the button's bounds and the live checklist's bounds.
struct ScanButtonExpansion: View, Animatable {
    let from: CGRect
    let to: CGRect
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: interpolate(13, Metrics.radius), style: .continuous)

        shape.fill(Palette.surface)
            .overlay { shape.strokeBorder(Palette.hairline) }
            .overlay { ScanButtonSurface(shape: shape).opacity(1 - progress * progress) }
            .overlay { StartScanLabel().fixedSize().opacity(max(0, 1 - progress * 3)) }
            .frame(width: interpolate(from.width, to.width), height: interpolate(from.height, to.height))
            .opacity(min(1, (1 - progress) * 6))
            .position(x: interpolate(from.midX, to.midX), y: interpolate(from.midY, to.midY))
    }

    private func interpolate(_ start: CGFloat, _ end: CGFloat) -> CGFloat {
        start + (end - start) * progress
    }
}
