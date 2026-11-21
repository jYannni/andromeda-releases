import AppKit
import SwiftUI

/// Draws at a fixed size while individual parts move within and around the glyph.
struct SidebarGlyph: View {
    let symbol: String
    let driveIcon: NSImage?
    let emphasisColor: Color?
    let hover: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var emphasized: Bool { emphasisColor != nil }

    private var tint: Color {
        guard let emphasisColor else { return .secondary }
        return colorScheme == .light ? emphasisColor.mix(with: .black, by: 0.3) : emphasisColor
    }

    var body: some View {
        Group {
            if reduceMotion {
                artwork(at: 0)
            } else {
                KeyframeAnimator(initialValue: CGFloat.zero, trigger: hover) { time in
                    artwork(at: time)
                } keyframes: { _ in
                    MoveKeyframe(0)
                    LinearKeyframe(1, duration: 0.6)
                }
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(tint)
        .accessibilityHidden(true)
    }

    @ViewBuilder private func artwork(at time: CGFloat) -> some View {
        let motion = wave(time)
        switch symbol {
        case "chart.pie":
            pie(spread: motion)
        case "arrow.up.arrow.down":
            comparisonArrows(travel: motion)
        case "folder":
            scanningFolder(at: time)
        case "chart.xyaxis.line":
            trend(at: time)
        case "clock.arrow.circlepath":
            image(symbol).rotationEffect(.degrees(-32 * motion))
        case "square.grid.2x2", "square.grid.2x2.fill":
            grid(at: time, filled: symbol.hasSuffix(".fill"))
        case "icloud.and.arrow.down", "icloud.and.arrow.up":
            cloudTransfer(up: symbol.hasSuffix(".up"), travel: motion)
        case "folder.badge.gearshape":
            folderGear(turn: motion)
        case "externaldrive.badge.checkmark":
            driveWithCheck(at: time)
        case "target":
            target(at: time)
        case "gearshape":
            image(symbol).rotationEffect(.degrees(45 * motion))
        case "arrow.down.circle.fill":
            Circle().frame(width: 15, height: 15)
                .overlay {
                    image("arrow.down", size: 9)
                        .offset(y: 2.1 * motion)
                        .blendMode(.destinationOut)
                }
                .compositingGroup()
        case "externaldrive":
            if let driveIcon, !emphasized {
                Image(nsImage: driveIcon).resizable().scaledToFit().offset(x: -1.2 * motion)
            } else {
                image(symbol).offset(x: -1.2 * motion)
            }
        case "gearshape.2.fill":
            image(symbol).rotationEffect(.degrees(18 * motion))
        case "doc.fill":
            image(symbol).rotation3DEffect(.degrees(-40 * motion), axis: (x: 0, y: 1, z: 0),
                                           anchor: .leading, perspective: 0)
        case "hammer.fill":
            image(symbol).rotationEffect(.degrees(25 * sin(2 * .pi * time) * motion), anchor: .bottomLeading)
        case "iphone":
            image(symbol).rotationEffect(.degrees(11 * sin(2 * .pi * time) * motion))
        case "envelope.fill":
            image(symbol).rotation3DEffect(.degrees(-40 * motion), axis: (x: 1, y: 0, z: 0),
                                           anchor: .bottom, perspective: 0)
        case "message.fill":
            message(at: time)
        case "photo.fill":
            image(symbol)
                .overlay {
                    Rectangle()
                        .fill(.white.opacity(0.42 * motion))
                        .frame(width: 4, height: 20)
                        .rotationEffect(.degrees(18))
                        .offset(x: -10 + 20 * time)
                        .blendMode(.sourceAtop)
                }
                .compositingGroup()
        case "icloud.fill":
            image(symbol).offset(x: 1.8 * sin(2 * .pi * time) * motion)
        case "person.2.fill":
            image(symbol).rotationEffect(.degrees(11 * motion), anchor: .bottom)
        case "apple.logo":
            image(symbol).rotationEffect(.degrees(-12 * motion))
        default:
            image(symbol)
        }
    }

    private var lineWidth: CGFloat { emphasized ? 1.65 : 1.2 }

    private func image(_ name: String, size: CGFloat = 15) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.monochrome)
            .font(.system(size: size, weight: emphasized ? .bold : .regular))
    }

    // A one-shot displacement that eases out and returns to the resting pose.
    private func wave(_ time: CGFloat) -> CGFloat {
        let sine = sin(.pi * min(1, max(0, time)))
        return sine * sine
    }

    private func pie(spread: CGFloat) -> some View {
        Canvas { context, size in
            let center = size.width / 2
            let separation = 0.9 + 1.6 * spread
            let smallSlice = CGPoint(x: center + separation, y: center - separation)
            let largeSlice = CGPoint(x: center - separation * 0.55, y: center + separation * 0.55)
            for (center, start, end) in [(smallSlice, -90.0, 0.0), (largeSlice, 0.0, 270.0)] {
                let slice = Path { path in
                    path.move(to: center)
                    path.addArc(center: center, radius: 5.9, startAngle: .degrees(start),
                                endAngle: .degrees(end), clockwise: false)
                    path.closeSubpath()
                }
                context.stroke(slice, with: .foreground,
                               style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 20, height: 20)
    }

    private func comparisonArrows(travel: CGFloat) -> some View {
        Canvas { context, _ in
            let distance = 2.2 * travel
            let arrows = Path { path in
                path.addLines([
                    CGPoint(x: 1.5, y: 6.5 - distance),
                    CGPoint(x: 4.5, y: 3.5 - distance),
                    CGPoint(x: 7.5, y: 6.5 - distance),
                ])
                path.addLines([CGPoint(x: 4.5, y: 3.5 - distance), CGPoint(x: 4.5, y: 12.5 - distance)])
                path.addLines([
                    CGPoint(x: 8.5, y: 9.5 + distance),
                    CGPoint(x: 11.5, y: 12.5 + distance),
                    CGPoint(x: 14.5, y: 9.5 + distance),
                ])
                path.addLines([CGPoint(x: 11.5, y: 12.5 + distance), CGPoint(x: 11.5, y: 3.5 + distance)])
            }
            context.stroke(arrows, with: .foreground,
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 16, height: 16)
    }

    private func scanningFolder(at time: CGFloat) -> some View {
        let visibility = min(1, 4 * wave(time))
        return ZStack {
            image("folder")
            ZStack {
                Circle().frame(width: 7, height: 7)
                    .blendMode(.destinationOut)
                image("magnifyingglass", size: 9)
            }
            .opacity(visibility)
            .offset(x: -5 + 10 * time, y: 3.5)
        }
        .compositingGroup()
    }

    private func trend(at time: CGFloat) -> some View {
        let trace = Path { path in
            path.addLines([CGPoint(x: 4, y: 11), CGPoint(x: 7, y: 7),
                           CGPoint(x: 10, y: 9), CGPoint(x: 14, y: 4)])
        }
        let stroke = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        return ZStack {
            Path { path in
                path.addLines([CGPoint(x: 2, y: 2), CGPoint(x: 2, y: 14), CGPoint(x: 15, y: 14)])
            }
            .stroke(style: stroke)
            trace.stroke(style: stroke).opacity(1 - 0.6 * wave(time))
            trace.trim(from: 0, to: time).stroke(style: stroke).opacity(wave(time))
        }
        .frame(width: 16, height: 16)
    }

    private func grid(at time: CGFloat, filled: Bool) -> some View {
        ZStack {
            ForEach(0..<4) { index in
                let tile = RoundedRectangle(cornerRadius: 1.1)
                let spread = filled ? 0 : 1.35 * wave(time)
                let lift = filled ? 1.6 * wave((time - 0.12 * CGFloat(index)) / 0.64) : 0
                Group {
                    if filled { tile }
                    else { tile.strokeBorder(lineWidth: lineWidth) }
                }
                .frame(width: 5.4, height: 5.4)
                .offset(x: index.isMultiple(of: 2) ? -3.5 - spread : 3.5 + spread,
                        y: (index < 2 ? -3.5 - spread : 3.5 + spread) - lift)
            }
        }
        .frame(width: 16, height: 16)
    }

    private func cloudTransfer(up: Bool, travel: CGFloat) -> some View {
        ZStack {
            image("icloud").offset(y: -1)
            Capsule().frame(width: 5, height: 7).offset(y: 4)
                .blendMode(.destinationOut)
            image(up ? "arrow.up" : "arrow.down", size: 9)
                .offset(y: 4 + (up ? -2.5 : 2.5) * travel)
        }
        .compositingGroup()
    }

    private func folderGear(turn: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            image("folder")
            Circle().frame(width: 7, height: 7).blendMode(.destinationOut)
            image("gearshape.fill", size: 8).rotationEffect(.degrees(65 * turn))
        }
        .compositingGroup()
    }

    private func driveWithCheck(at time: CGFloat) -> some View {
        ZStack(alignment: .bottomTrailing) {
            image("externaldrive")
            Circle().frame(width: 7, height: 7).blendMode(.destinationOut)
            image("checkmark.circle.fill", size: 8).offset(y: -1.6 * wave(time))
        }
        .compositingGroup()
    }

    private func target(at time: CGFloat) -> some View {
        let ring = 9 - 2 * wave(time)
        return ZStack {
            Circle().strokeBorder(lineWidth: lineWidth)
                .frame(width: 15, height: 15)
            Circle().strokeBorder(lineWidth: lineWidth)
                .frame(width: ring, height: ring)
            Circle().frame(width: 2.5, height: 2.5)
        }
    }

    private func message(at time: CGFloat) -> some View {
        image("message")
            .overlay {
                HStack(spacing: 1.1) {
                    ForEach(0..<3) { index in
                        Circle().frame(width: 1.55, height: 1.55)
                            .opacity(wave((time - 0.12 * CGFloat(index)) / 0.62))
                    }
                }
                .offset(y: -1)
            }
    }
}
