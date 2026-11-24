import AppKit

@MainActor
func menuBarGalaxy() -> NSImage {
    // Use the same core and two arms as the app icon, without the background or release badge.
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
        guard let context = NSGraphicsContext.current?.cgContext else { return false }
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: 0.024, y: 0.024)
        context.setFillColor(.black)

        context.saveGState()
        context.rotate(by: -18 * .pi / 180)
        context.translateBy(x: -512, y: -512)
        let arms = CGMutablePath()
        arms.move(to: CGPoint(x: 179, y: 480))
        arms.cubic(to: (536, 236), from: (225, 344), via: (369, 249))
        arms.cubic(to: (850, 414), from: (711, 222), via: (842, 307))
        arms.cubic(to: (626, 619), from: (858, 518), via: (754, 611))
        arms.cubic(to: (557, 612), from: (600, 621), via: (577, 618))
        arms.cubic(to: (719, 470), from: (637, 590), via: (715, 535))
        arms.cubic(to: (550, 356), from: (724, 405), via: (650, 361))
        arms.cubic(to: (179, 480), from: (409, 348), via: (279, 397))
        arms.closeSubpath()
        arms.move(to: CGPoint(x: 842, y: 548))
        arms.cubic(to: (485, 786), from: (793, 690), via: (641, 774))
        arms.cubic(to: (174, 611), from: (311, 799), via: (184, 718))
        arms.cubic(to: (379, 408), from: (164, 508), via: (259, 420))
        arms.cubic(to: (462, 414), from: (410, 404), via: (438, 406))
        arms.cubic(to: (304, 550), from: (382, 434), via: (310, 486))
        arms.cubic(to: (474, 668), from: (297, 615), via: (371, 663))
        arms.cubic(to: (842, 548), from: (615, 676), via: (741, 627))
        arms.closeSubpath()
        context.addPath(arms)
        context.fillPath()
        context.restoreGState()

        context.rotate(by: -22 * .pi / 180)
        context.fillEllipse(in: CGRect(x: -79, y: -58, width: 158, height: 116))
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "Andromeda Storage"
    return image
}

private extension CGMutablePath {
    func cubic(to end: (CGFloat, CGFloat), from first: (CGFloat, CGFloat), via second: (CGFloat, CGFloat)) {
        addCurve(to: CGPoint(x: end.0, y: end.1),
                 control1: CGPoint(x: first.0, y: first.1), control2: CGPoint(x: second.0, y: second.1))
    }
}
