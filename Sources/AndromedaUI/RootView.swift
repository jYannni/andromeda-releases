import AndromedaAppModel
import SwiftUI

public struct RootView: View {
    let model: AppModel
    @Bindable var ui: UIState
    let showUpdate: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: AppModel, ui: UIState, showUpdate: (() -> Void)? = nil) {
        self.model = model
        self.ui = ui
        self.showUpdate = showUpdate
    }

    public var body: some View {
        if model.hasCompletedOnboarding { shell } else { OnboardingView(model: model) }
    }

    private var shell: some View {
        HStack(spacing: 0) {
            SidebarView(model: model, ui: ui, showUpdate: showUpdate)
                .frame(width: ui.sidebarIsCompact ? 56 : 246)
            VStack(spacing: 0) {
                if let note = model.access.relaunchNote { banner(note) { model.access.relaunchNote = nil } }
                if let note = ui.problem { banner(note, symbol: "exclamationmark.triangle.fill", tint: .orange) { ui.problem = nil } }
                if let drive = model.drives.nextLocationReminder {
                    DriveStorageLocationReminder(drives: model.drives, drive: drive)
                        .id(drive.id)
                        .padding(.horizontal, 16).padding(.top, 12)
                }
                if let title = ui.spacePlanStepTitle {
                    HStack(spacing: 10) {
                        Button("Back to Space Plan", systemImage: "chevron.left") {
                            ui.returnToSpacePlan(model: model)
                        }
                        .fixedSize()
                        Text(title).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            .truncationMode(.middle).help(title)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 10)
                    .background(Palette.surface)
                }
                DetailView(model: model, ui: ui)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Palette.canvas)
            .clipShape(.rect(topLeadingRadius: Metrics.windowContentCorner))
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: ui.sidebarIsCompact)
        .background(Palette.chrome)
        .containerBackground(Palette.chrome, for: .window)
        .navigationTitle(UICopy.appName)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                let title = ui.sidebarIsCompact ? "Expand Sidebar" : "Minimize Sidebar"
                Button(title, systemImage: "sidebar.left") { ui.sidebarIsCompact.toggle() }
                    .labelStyle(.iconOnly)
                    .help(title)
            }
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .primaryAction) {
                let title = model.scan.lastResult == nil ? UICopy.scan : UICopy.scanAgain
                Button {
                    Task { await model.scan() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.clockwise")
                        Text(title).padding(.trailing, 8)
                    }
                }
                .accessibilityLabel(title)
                .help(UICopy.scanHelp)
                .disabled(!model.canScan)
            }
        }
        .onChange(of: ui.reviewRequested) { ui.resolveRequests(removal: model.removal) }
        .onChange(of: ui.rebuildRequested) { ui.resolveRequests(removal: model.removal) }
        .sheet(isPresented: Binding(get: { ui.confirm != nil }, set: { if !$0 { ui.confirm = nil } })) {
            if let summary = ui.confirm {
                ConfirmSheet(summary: summary, onCancel: { ui.confirm = nil }) {
                    if let confirmed = ui.takeConfirmed() {
                        Task {
                            let started = await model.removal.execute(confirmed)
                            // A refused run has no receipt; its reason shows as a banner instead.
                            if !started { ui.receiptShowing = false; ui.problem = model.removal.actionProblem }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $ui.receiptShowing) { ReceiptView(model: model, ui: ui) }
        .sheet(isPresented: $ui.helperSheetRequested) {
            HelperSheet(helper: model.helper) { ui.helperSheetRequested = false }
        }
        .onChange(of: model.pages.map(\.id)) {
            switch ui.destination {
            case .page(let bucket), .browseCategory(let bucket):
                if !model.pages.contains(where: { $0.id == bucket }) { ui.destination = .overview }
            default: break
            }
        }
    }

    private func banner(
        _ note: String, symbol: String = "info.circle.fill", tint: Color = .accentColor, dismiss: @escaping () -> Void
    ) -> some View {
        Banner(text: note, symbol: symbol, tint: tint, actionTitle: UICopy.dismiss, action: dismiss)
            .padding(.horizontal, 16).padding(.top, 12)
    }
}
