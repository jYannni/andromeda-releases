import AndromedaAppModel
import Foundation
import SwiftUI

public struct WhatsNewView: View {
    private let releases: [ReleaseHistoryEntry]

    public init(releases: [ReleaseHistoryEntry]) { self.releases = releases }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if releases.isEmpty {
                    Text("Release history is unavailable in this build.")
                        .foregroundStyle(.secondary)
                }
                ForEach(releases) { release in
                    if release.id != releases.first?.id { Divider() }
                    releaseSection(release)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(minWidth: 360, minHeight: 340)
        .background(Palette.canvas)
    }

    private func releaseSection(_ release: ReleaseHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                Text(release.date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: .gmt)))
                    .font(.headline)
                Spacer()
                Text(release.version)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(release.sections) { section in
                VStack(alignment: .leading, spacing: 7) {
                    Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                            Text((try? AttributedString(markdown: item,
                                                       options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                                 ?? AttributedString(item))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }
}
