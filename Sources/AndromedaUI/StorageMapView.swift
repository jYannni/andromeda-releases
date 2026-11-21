import AndromedaCore
import SwiftUI

/// Splits the largest available side at each level. Every rectangle retains its share of the area.
enum StorageMapLayout {
    static func rectangles(for weights: [Int64], in bounds: CGRect) -> [CGRect] {
        guard !weights.isEmpty, weights.allSatisfy({ $0 > 0 }) else { return [] }
        return split(weights[...], total: weights.reduce(0) { $0 + Double($1) }, in: bounds)
    }

    private static func split(_ weights: ArraySlice<Int64>, total: Double, in bounds: CGRect) -> [CGRect] {
        guard weights.count > 1, let first = weights.first else { return [bounds] }
        var boundary = weights.index(after: weights.startIndex)
        var left = Double(first)
        let middle = total / 2
        while boundary < weights.index(before: weights.endIndex) {
            let next = left + Double(weights[boundary])
            guard abs(next - middle) < abs(left - middle) else { break }
            left = next
            boundary = weights.index(after: boundary)
        }
        let fraction = CGFloat(left / total)
        let (leading, remaining) = bounds.divided(
            atDistance: fraction * max(bounds.width, bounds.height),
            from: bounds.width >= bounds.height ? .minXEdge : .minYEdge)
        let tail = weights[boundary...]
        return split(weights[..<boundary], total: left, in: leading)
            + split(tail, total: tail.reduce(0) { $0 + Double($1) }, in: remaining)
    }
}

struct StorageMapView<FolderActions: View>: View {
    let contents: StorageBrowser.MapContents
    let open: (StorageBrowser.Entry) -> Void
    let showList: () -> Void
    @ViewBuilder let folderActions: (StorageBrowser.Entry) -> FolderActions
    @State private var hoveredTile: Tile?

    private struct Tile: Identifiable {
        let entry: StorageBrowser.Entry?
        let bytes: Int64
        var id: Int { entry?.id ?? -1 }
        var title: String { entry?.name ?? "Smaller items" }
        var size: String { (entry?.incomplete == true ? "At least " : "") + ByteFormat.string(bytes) }
        var symbol: String { entry.map { $0.isFolder ? "folder.fill" : "doc" } ?? "ellipsis" }
        var action: String {
            guard let entry else { return "Show smaller items in List" }
            return entry.isFolder ? "Open \(title)" : "Quick Look \(title)"
        }
    }

    var body: some View {
        let tiles = contents.entries.map { Tile(entry: $0, bytes: $0.bytes) }
            + (contents.smallerBytes > 0 ? [Tile(entry: nil, bytes: contents.smallerBytes)] : [])
        VStack(alignment: .leading, spacing: 10) {
            Text("Larger tiles use more space on disk. Click a folder to see what’s inside.")
                .font(.callout).foregroundStyle(.secondary)
            if tiles.isEmpty {
                HStack {
                    Text("No measured space to map.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Show List", action: showList)
                }
            } else {
                GeometryReader { geometry in
                    let frames = StorageMapLayout.rectangles(for: tiles.map(\.bytes), in: CGRect(origin: .zero, size: geometry.size))
                    ZStack {
                        ForEach(Array(zip(tiles, frames)), id: \.0.id) { tile, frame in
                            tileButton(tile, frame: frame)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let hovered = frames.firstIndex { $0.contains(point) && ($0.width < 92 || $0.height < 56) }
                                .map { tiles[$0] }
                            if hovered?.id != hoveredTile?.id { hoveredTile = hovered }
                        case .ended:
                            hoveredTile = nil
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        if let tile = hoveredTile {
                            HStack(spacing: 8) {
                                Text(tile.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                                Text(tile.size).foregroundStyle(.secondary).monospacedDigit().fixedSize()
                            }
                            .font(.callout)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                            .padding(8)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .frame(height: 330)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Storage map")
                if contents.smallerBytes > 0 {
                    Button("Show smaller items in List", action: showList).buttonStyle(.link)
                }
            }
        }
        .card()
        .onChange(of: tiles.map(\.id)) { hoveredTile = nil }
    }

    private func tileButton(_ tile: Tile, frame: CGRect) -> some View {
        let tint: Color = tile.entry.map { $0.isFolder ? .accentColor : .teal } ?? .secondary
        let shape = RoundedRectangle(cornerRadius: 6)
        return ZStack(alignment: .bottomTrailing) {
            tileLabel(tile, frame: frame, tint: tint, shape: shape)
            if let entry = tile.entry, entry.isFolder, frame.width >= 110, frame.height >= 75 {
                folderActions(entry)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(7)
            }
        }
        .position(x: frame.midX, y: frame.midY)
    }

    private func tileLabel(_ tile: Tile, frame: CGRect, tint: Color, shape: RoundedRectangle) -> some View {
        Button {
            if let entry = tile.entry { open(entry) }
            else { showList() }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                if frame.width >= 92, frame.height >= 37 {
                    Label(tile.title, systemImage: tile.symbol).font(.callout.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                    if frame.height >= 56 {
                        Text(tile.size).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                } else if frame.width >= 26, frame.height >= 24 {
                    Image(systemName: tile.symbol).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(frame.width >= 92 && frame.height >= 37 ? 9 : 0)
            .frame(width: max(0, frame.width - 2), height: max(0, frame.height - 2), alignment: .topLeading)
            .background(tint.opacity(0.17), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.25)))
            .clipShape(shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tile.title) · \(tile.size)")
        .accessibilityLabel(tile.action)
        .accessibilityValue(tile.size)
        .accessibilityActions {
            if let entry = tile.entry, entry.isFolder {
                folderActions(entry)
            }
        }
        .contextMenu {
            if let entry = tile.entry, entry.isFolder {
                folderActions(entry)
            }
        }
    }
}
