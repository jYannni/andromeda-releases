import AppKit
import AndromedaAppModel
import AndromedaCore
import AndromedaOrganize
import SwiftUI

/// A raised surface: the one container shape in the app. Rows that belong together share one
/// surface (`InsetGroup`) instead of each getting its own.
struct Card: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(Card(padding: padding)) }
    /// Padding for a row inside an `InsetGroup`.
    func groupRow() -> some View {
        padding(.horizontal, 16).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
}

enum Metrics {
    static let radius: CGFloat = 12
    static let windowContentCorner: CGFloat = 18
    static let gutter: CGFloat = 32
    static let sectionSpacing: CGFloat = 28
    static let columnWidth: CGFloat = 920
}

/// Surfaces sit a step above the window in both appearances; the hairline keeps them crisp on any wallpaper tint.
enum Palette {
    static let chrome = Color(light: 0xEDEDF0, dark: 0x252528)
    static let canvas = Color(light: 0xF4F4F6, dark: 0x1D1D1F)
    static let surface = Color(light: 0xFFFFFF, dark: 0x2A2A2D)
    static let hairline = Color(light: 0xE2E2E6, dark: 0x3A3A3E)
    static let chip = Color.primary.opacity(0.07)
}

/// Several rows on one surface, separated by inset dividers, like a System Settings group.
/// Each child should pad itself with `groupRow()`.
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    if i > 0 { Divider().padding(.leading, 16) }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// `InsetGroup` for long lists: rows are built as they scroll into view (a big folder has thousands).
struct LazyInsetList<Item, Row: View>: View {
    let items: [Item]
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                if i > 0 { Divider().padding(.leading, 16) }
                row(items[i])
            }
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                .strokeBorder(Palette.hairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous))
    }
}

/// A rounded square holding a symbol: the app's way of naming a place (page headers, onboarding, empty states).
struct SymbolTile: View {
    let symbol: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A cloud provider as people know it: its own app's icon (Finder's iCloud Drive for iCloud), the way
/// Finder's sidebar shows them. Falls back to a generic cloud tile when the provider's app isn't installed.
struct ProviderIconView: View {
    let provider: CloudProvider
    var size: CGFloat = 32

    var body: some View {
        if let image = Self.icon(provider) {
            Image(nsImage: image).resizable().interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            SymbolTile(symbol: Style.providerSymbol(provider), tint: Style.providerTint(provider), size: size)
        }
    }

    static func icon(_ provider: CloudProvider) -> NSImage? {
        let workspace = NSWorkspace.shared
        if provider == .iCloudDrive {
            let path = "/System/Library/CoreServices/Finder.app/Contents/Applications/iCloud Drive.app"
            return FileManager.default.fileExists(atPath: path) ? workspace.icon(forFile: path) : nil
        }
        let ids: [String] = switch provider {
        case .googleDrive: ["com.google.drivefs"]
        case .oneDrive: ["com.microsoft.OneDrive-mac", "com.microsoft.OneDrive"]
        case .dropbox: ["com.getdropbox.dropbox"]
        case .iCloudDrive: []
        }
        return ids.lazy.compactMap { workspace.urlForApplication(withBundleIdentifier: $0) }.first
            .map { workspace.icon(forFile: $0.path) }
    }
}

/// An empty page's message, centred in the space under the page header.
struct EmptyState: View {
    let title: String
    let symbol: String
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity)
        // The page scrolls, so "centred" means within most of the visible height, below the header.
        .containerRelativeFrame(.vertical, alignment: .center) { height, _ in max(280, height - 180) }
    }
}

/// The name as a mark in SF Rounded with tightened spacing.
struct Wordmark: View {
    var size: CGFloat = 18

    var body: some View {
        Text(UICopy.appName)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .kerning(-size * 0.025)
            .accessibilityLabel(UICopy.appName)
    }
}

/// The sidebar's masthead: icon, wordmark and when the disk was last measured.
struct Masthead: View {
    var scanned: String?

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Wordmark(size: 19)
                if let scanned { Text(scanned).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.top, 4).padding(.bottom, 10)
        .accessibilityElement(children: .combine)
    }
}

/// Uses the bundled color artwork so the Dock's icon palette does not tint the in-app brand.
struct AppIconView: View {
    @Environment(\.appearsActive) private var appearsActive
    var size: CGFloat = 96
    var image: NSImage = Self.colorIcon

    private static let colorIcon: NSImage = Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
        .flatMap { NSImage(contentsOf: $0) }
        ?? NSApplication.shared.applicationIconImage
        ?? NSImage(size: .zero)

    var body: some View {
        Image(nsImage: image)
            .renderingMode(.original)
            .resizable().interpolation(.high)
            .saturation(appearsActive ? 1 : 0)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Every page opens the same way: tile, title, one line of what the page is for, and its main action.
struct PageHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var tint: Color = .accentColor
    /// A Finder icon in place of the symbol tile (a drive's own icon).
    var icon: NSImage?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44).accessibilityHidden(true)
            } else if let symbol {
                SymbolTile(symbol: symbol, tint: tint, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 24, weight: .bold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            trailing
        }
    }
}

extension PageHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, tint: Color = .accentColor) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, tint: tint) { EmptyView() }
    }
}

/// The top of every sheet: what it is about and what happens if you go on.
struct SheetHeader: View {
    let title: String
    var subtitle: String?
    var symbol: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SymbolTile(symbol: symbol, tint: tint, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title3.weight(.bold)).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// A capsule label for counts and evidence ("2 of 2", "Same name").
struct Chip: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background((tint ?? .primary).opacity(tint == nil ? 0.07 : 0.14), in: Capsule())
    }
}

/// A one-line notice above the page: an icon, the text, and its dismiss button.
struct Banner: View {
    let text: String
    var symbol = "info.circle.fill"
    var tint: Color = .accentColor
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            if let actionTitle, let action { Button(actionTitle, action: action) }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// A big number over a small label, for plan and run summaries.
struct StatTile: View {
    let value: String
    let label: String
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold)).monospacedDigit()
                .foregroundStyle(tint ?? .primary)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 12)
        .accessibilityElement(children: .combine)
    }
}

extension EnvironmentValues {
    /// Off only in render tests: `ImageRenderer` draws nothing inside a `ScrollView`.
    @Entry var pageIsScrollable = true
}

/// A page's scrolling column: 24pt gutters, readable width.
struct PageColumn<Content: View>: View {
    @Environment(\.pageIsScrollable) private var scrollable
    /// Each change to a non-nil key scrolls the page back to its top, e.g. when a receipt replaces a long plan (T11 F3).
    var scrollsToTopOn: AnyHashable?
    @ViewBuilder var content: Content

    init(scrollsToTopOn: AnyHashable? = nil, @ViewBuilder content: () -> Content) {
        self.scrollsToTopOn = scrollsToTopOn
        self.content = content()
    }

    private func column(viewportWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 20) { content }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Metrics.gutter).padding(.top, 24).padding(.bottom, 40)
            .frame(width: min(viewportWidth, Metrics.columnWidth + Metrics.gutter * 2))
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: scrollable ? nil : .infinity, alignment: .top)
    }

    var body: some View {
        GeometryReader { viewport in
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView { column(viewportWidth: viewport.size.width).id(PageColumnTop.id) }
                        .onChange(of: scrollsToTopOn) { _, now in
                            // Only when a new key appears (not when it goes away), and after the new content's layout.
                            guard now != nil else { return }
                            DispatchQueue.main.async { proxy.scrollTo(PageColumnTop.id, anchor: .top) }
                        }
                }
            } else {
                column(viewportWidth: viewport.size.width)
            }
        }
        .background(Palette.canvas)
    }
}

private enum PageColumnTop { static let id = "page-column-top" }

/// An inline list that grows with short disclosures and scrolls within a fixed area for long ones.
struct ScrollablePathList: View {
    let paths: [String]
    @ScaledMetric(relativeTo: .caption) private var rowHeight = 20.0

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(paths, id: \.self) { path in
                    Text(path)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(path)
                        .frame(height: rowHeight)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 10)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(CGFloat(paths.count) * rowHeight, 168))
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct SectionHeading: View {
    let title: String
    var subtitle: String?
    /// A small tile beside the title, for sections inside Settings.
    var symbol: String?
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            if let symbol { SymbolTile(symbol: symbol, tint: tint, size: 26) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.top, symbol == nil ? 8 : 0)
    }
}

// MARK: Colours (rev G, G-R5)

extension Color {
    /// A colour with its own light and dark values, resolved when drawn.
    init(light: UInt32, dark: UInt32) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ns(dark) : ns(light)
        })
    }
}

enum Style {
    /// Andromeda's own palette: one distinct colour per category, with a dark-mode variant.
    static func bucketColor(_ bucket: AppleBucket) -> Color {
        switch bucket {
        case .applications: Color(light: 0x3B7DDD, dark: 0x5B9BF0)
        case .documents: Color(light: 0xE8A33D, dark: 0xF0B95A)
        case .photos: Color(light: 0xD9558F, dark: 0xE9739F)
        case .mail: Color(light: 0x3FA7C9, dark: 0x5CC0E0)
        case .messages: Color(light: 0x4DB86A, dark: 0x66CC82)
        case .icloudDrive: Color(light: 0x7A6BDB, dark: 0x968AEA)
        case .iosFiles: Color(light: 0xD9743A, dark: 0xE88C55)
        case .developer: Color(light: 0xA0714F, dark: 0xBB8B68)
        case .otherUsers: Color(light: 0xA8A04A, dark: 0xC2BA63)
        case .macOS: Color(light: 0x2E9E8F, dark: 0x48B8A8)
        case .systemData: Color(light: 0x6E7B8B, dark: 0x8794A6)  // neutral-ish slate
        }
    }

    static let unaccountedColor = Color.gray

    /// The fallback when a provider's app isn't installed: a cloud, told apart by colour.
    static func providerSymbol(_ p: CloudProvider) -> String { p == .iCloudDrive ? "icloud.fill" : "cloud.fill" }

    static func providerTint(_ p: CloudProvider) -> Color {
        switch p {
        case .iCloudDrive: .blue
        case .googleDrive: .green
        case .oneDrive: .indigo
        case .dropbox: .cyan
        }
    }

    /// The symbol a category uses in the sidebar and on its page.
    static func symbol(_ bucket: AppleBucket) -> String {
        switch bucket {
        case .systemData: "gearshape.2.fill"
        case .documents: "doc.fill"
        case .developer: "hammer.fill"
        case .iosFiles: "iphone"
        case .mail: "envelope.fill"
        case .messages: "message.fill"
        case .photos: "photo.fill"
        case .icloudDrive: "icloud.fill"
        case .macOS: "apple.logo"
        case .otherUsers: "person.2.fill"
        case .applications: "square.grid.2x2.fill"
        }
    }

    static func color(_ kind: BarSegment.Kind) -> Color {
        switch kind {
        case .bucket(let b): bucketColor(b)
        case .unaccounted: unaccountedColor
        }
    }
}
