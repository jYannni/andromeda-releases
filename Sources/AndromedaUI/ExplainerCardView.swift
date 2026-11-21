import AndromedaAppModel
import SwiftUI

struct ExplainerCardView: View {
    let card: ExplainerCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(card.title, systemImage: "lightbulb").font(.headline).labelStyle(TintedIconLabel())
            Text(card.body).font(.callout)
            Divider().padding(.vertical, 2)
            Text(UICopy.whatYouCanDo).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(card.whatYouCanDo).font(.callout).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// A label whose icon takes the accent colour, for headings inside cards.
struct TintedIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundStyle(Color.accentColor)
            configuration.title
        }
    }
}
