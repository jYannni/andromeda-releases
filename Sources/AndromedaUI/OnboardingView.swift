import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct OnboardingView: View {
    let model: AppModel
    @Environment(\.pageIsScrollable) private var scrollable

    var body: some View {
        Group {
            if scrollable {
                GeometryReader { viewport in
                    ScrollView {
                        content.frame(minHeight: viewport.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            } else {
                content.frame(maxHeight: .infinity)
            }
        }
        .background(Palette.canvas)
    }

    private var content: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                AppIconView(size: 92)
                Wordmark(size: 46)
                    .accessibilityLabel(UICopy.welcomeTitle)
                    .accessibilityAddTraits(.isHeader)
                Text(UICopy.welcomeSubtitle).font(.title3).foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                EnglishSpellingPicker(model: model)
                    .fixedSize()
                    .padding(.bottom, 8)
                Button {
                    Task { await model.completeOnboarding() }
                } label: {
                    Text(model.access.fda == .granted ? UICopy.scanMyMac : UICopy.scanWithLimitedAccess)
                        .frame(minWidth: 180)
                }
                .buttonStyle(.borderedProminent).controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canScan)
                Text(UICopy.scanPrivacy).font(.callout).foregroundStyle(.secondary)
            }
            access.frame(maxWidth: 520)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 32).padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private var access: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.access.fda == .granted {
                Label(UICopy.accessOn, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold)).foregroundStyle(.green)
            } else {
                HStack {
                    Label(UICopy.accessTitle, systemImage: "lock.fill").font(.headline)
                    Spacer(minLength: 8)
                    Button(UICopy.openSettings) { model.access.openSettings() }
                }
                Text(UICopy.accessBody).font(.callout).foregroundStyle(.secondary)
            }
            if let notice = model.access.blockedNoticeNote {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            if let steps = model.access.fallbackSteps {
                Text(steps).font(.callout).foregroundStyle(.secondary)
            }
            if let note = model.access.relaunchNote {
                HStack {
                    Text(note).font(.callout)
                    Spacer()
                    Button(UICopy.dismiss) { model.access.relaunchNote = nil }
                }
            }
        }
        .multilineTextAlignment(.leading)
        .card(padding: 18)
    }
}
