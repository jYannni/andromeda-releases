import AndromedaAppModel
import SwiftUI

struct EnglishSpellingPicker: View {
    @Bindable var model: AppModel

    var body: some View {
        Picker("English spelling", selection: $model.englishSpelling) {
            ForEach(EnglishSpelling.allCases) { spelling in
                Text(spelling.title).tag(spelling)
            }
        }
    }
}
