import AndromedaAppModel
import AndromedaCore
import SwiftUI

/// Width maths for the bar, kept apart from drawing so it can be tested.
enum SpaceBarLayout {
    /// One width per fraction. Gaps come out of `available` first; a segment narrower than `minWidth`
    /// is widened to it, and the extra comes off the largest segment so the total doesn't change.
    static func widths(fractions: [Double], available: CGFloat, gap: CGFloat = 1, minWidth: CGFloat = 2) -> [CGFloat] {
        guard !fractions.isEmpty else { return [] }
        let usable = max(0, available - gap * CGFloat(fractions.count - 1))
        var widths = fractions.map { CGFloat($0) * usable }
        var borrowed: CGFloat = 0
        for i in widths.indices where widths[i] < minWidth {
            borrowed += minWidth - widths[i]
            widths[i] = minWidth
        }
        if borrowed > 0, let big = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[big] = max(minWidth, widths[big] - borrowed)
        }
        return widths
    }
}

/// The reconciliation bar and its legend. Fractions come from the model; the view only draws them.
/// Category segments and legend entries are buttons that call `onSelect` with the category.
struct SpaceBarView: View {
    let segments: [BarSegment]
    /// How much of the track the segments fill (used over capacity). The rest is drawn as free space.
    var usedFraction: Double = 1
    var height: CGFloat = 20
    let onSelect: (AppleBucket) -> Void

    private let gap: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geo in
                let filled = geo.size.width * CGFloat(min(1, max(0, usedFraction)))
                let widths = SpaceBarLayout.widths(fractions: segments.map(\.fraction), available: filled, gap: gap)
                HStack(spacing: gap) {
                    ForEach(Array(segments.enumerated()), id: \.element.id) { i, s in
                        segmentView(s).frame(width: widths[i])
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: height * 0.3, style: .continuous))
            }
            .frame(height: height)
            FlowLayout(spacing: 18, lineSpacing: 8) {
                ForEach(segments) { s in legendEntry(s) }
            }
        }
    }

    private func fill(_ s: BarSegment) -> some View {
        Rectangle().fill(Style.color(s.kind).gradient)
    }

    @ViewBuilder private func segmentView(_ s: BarSegment) -> some View {
        if case .bucket(let bucket) = s.kind {
            Button { onSelect(bucket) } label: { fill(s).contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("\(s.label): \(ByteFormat.string(s.bytes))")
                .accessibilityLabel(s.accessibilityLabel)
        } else {
            fill(s).accessibilityElement().accessibilityLabel(s.accessibilityLabel)
        }
    }

    @ViewBuilder private func legendEntry(_ s: BarSegment) -> some View {
        let content = HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous).fill(Style.color(s.kind)).frame(width: 10, height: 10)
            Text(s.label).font(.callout)
            Text(ByteFormat.string(s.bytes)).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        if case .bucket(let bucket) = s.kind {
            Button { onSelect(bucket) } label: { content.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(s.accessibilityLabel)
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(s.accessibilityLabel)
        }
    }
}

/// Lays children left to right and wraps to a new line when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (offsets: [CGPoint], size: CGSize) {
        var offsets: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            offsets.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return (offsets, CGSize(width: maxX, height: y + lineHeight))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(bounds.width, subviews)
        for (sub, offset) in zip(subviews, laid.offsets) {
            sub.place(at: CGPoint(x: bounds.minX + offset.x, y: bounds.minY + offset.y), proposal: .unspecified)
        }
    }
}
