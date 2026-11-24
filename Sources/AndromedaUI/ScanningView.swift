import AndromedaAppModel
import AndromedaCore
import SwiftUI

/// The scan's stages as a checklist, live counts under the running one, the folder or entry being read
/// behind a Details disclosure, elapsed time, and Cancel. No percentages: a walk can't know its total
/// without walking twice.
struct ScanningView: View {
    let stage: ScanStage
    var stages: [ScanStage] = [.checkingAccess]
    var progress: ScanProgress?
    var startedAt: Date?
    var isCancelling = false
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var onCancel: (() -> Void)?
    var revealsContent = true
    var onChecklistFrame: ((CGRect) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("scanDetailsExpanded") private var detailsExpanded = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 10) {
                AppIconView(size: 72)
                Text(UICopy.scanningTitle).font(.title2.weight(.bold))
                Text(UICopy.scanningNote).font(.callout).foregroundStyle(.secondary)
            }
            .opacity(revealsContent ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.24).delay(0.10), value: revealsContent)

            scanProgress
                .opacity(revealsContent ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.22).delay(0.30), value: revealsContent)
        }
        .frame(maxWidth: 480)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var scanProgress: some View {
        VStack(spacing: 20) {
            checklist
            if let current = currentText {
                DisclosureGroup(UICopy.scanDetails, isExpanded: $detailsExpanded) {
                    Text(current)
                        .font(.callout.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .foregroundStyle(.secondary)
            }
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Copy.Scan.elapsed(seconds: max(0, Int(context.date.timeIntervalSince(startedAt)))))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let onCancel {
                Button(isCancelling ? UICopy.stoppingScan : UICopy.cancelScan, action: onCancel)
                    .disabled(isCancelling)
                    .keyboardShortcut(.cancelAction)
            }
        }
    }

    private var checklist: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(stages, id: \.self) { s in stageRow(s) }
        }
        .card(padding: 20)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ScanExpansionSpace.detail)) } action: {
            onChecklistFrame?($0)
        }
    }

    @ViewBuilder private func stageRow(_ s: ScanStage) -> some View {
        let state = rowState(s)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                switch state {
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .running: ProgressView().controlSize(.small)
                case .waiting: Image(systemName: "circle").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(UICopy.stage(s))
                    .fontWeight(state == .running ? .semibold : .regular)
                    .foregroundStyle(state == .waiting ? .secondary : .primary)
                if state == .running, let p = progress, p.itemsChecked > 0 {
                    Text(Copy.Scan.counts(items: p.itemsChecked, bytes: p.bytesMeasured))
                        .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(UICopy.stageState(state))
    }

    private var currentText: String? {
        if let path = progress?.currentPath { return UICopy.nowReading(Copy.Scan.displayPath(path, home: home)) }
        if let entry = progress?.currentEntry { return UICopy.nowLookingAt(entry) }
        return nil
    }

    enum RowState { case done, running, waiting }

    private func rowState(_ s: ScanStage) -> RowState {
        guard let i = stages.firstIndex(of: s), let current = stages.firstIndex(of: stage) else {
            return s == stage ? .running : .waiting
        }
        return i < current ? .done : i == current ? .running : .waiting
    }
}

/// Before the first scan, or after a failed one: a message and one button.
struct ScanPromptView<ButtonContent: View>: View {
    let title: String
    let message: String
    let disabled: Bool
    @ViewBuilder var button: ButtonContent

    var body: some View {
        VStack(spacing: 14) {
            AppIconView(size: 88)
            Text(title).font(.title2.weight(.bold))
            Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
            button
                .disabled(disabled)
                .padding(.top, 4)
        }
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
