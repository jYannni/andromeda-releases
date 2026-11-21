import AndromedaAppModel
import SwiftUI

/// "Review N items". Hidden when the model has no title (nothing ticked, or removal is off).
struct ReviewButton: View {
    let model: AppModel
    let ui: UIState
    var allCategories = false

    var body: some View {
        if let title = model.removal.reviewButtonTitle {
            Button(allCategories ? "\(title) across categories" : title) { ui.requestReview() }
                .buttonStyle(.borderedProminent)
                .disabled(!model.removal.canEditSelection)
        }
    }
}
