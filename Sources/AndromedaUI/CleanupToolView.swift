import AndromedaAppModel
import AndromedaCore
import AppKit
import QuickLook
import SwiftUI

struct CleanupToolView: View {
    let model: AppModel
    let ui: UIState
    let tool: ToolCleanup

    @State private var review: ToolCleanup.Review?
    @State private var selected: Set<URL> = []
    @State private var refresh = 0
    @State private var scanning = false
    @State private var showModels = false
    @State private var modelConfirmation: ConfirmSummary?
    @State private var preview: URL?
    @State private var search = ""

    private var ai: Bool { tool == .aiClutter }
    private var visible: [ToolCleanup.Item] {
        (review?.items ?? []).filter {
            search.isEmpty || $0.title.localizedStandardContains(search) || $0.detail.localizedStandardContains(search)
        }
    }

    var body: some View {
        PageColumn {
            PageHeader(title: ai ? "AI Clutter" : "Mail Attachments",
                       subtitle: ai ? "Review local AI tool caches, logs, and models."
                           : "Find attachment downloads that match a copy in Apple Mail.",
                       symbol: ai ? "sparkles" : "paperclip", tint: ai ? .indigo : .cyan) {
                ToolBackButton(ui: ui)
                Button("Scan", systemImage: "arrow.clockwise") { refresh += 1 }
                    .buttonStyle(.borderedProminent).disabled(scanning || (!ai && model.access.fda != .granted))
            }
            if let reason = model.removal.removalDisabledReason { Banner(text: reason, symbol: "lock.fill") }
            if ai { models }
            if !ai, model.access.fda != .granted {
                Banner(text: "Full Disk Access lets Andromeda compare Mail downloads with copies in your mailboxes.",
                       symbol: "lock.fill", tint: .secondary, actionTitle: "Open Full Disk Access",
                       action: model.access.openSettings)
            }
            if scanning {
                ProgressView(ai ? "Checking AI tools…" : "Comparing Mail downloads…").card()
            } else if let review {
                results(review)
            } else if ai || model.access.fda == .granted {
                EmptyState(title: ai ? "Scan AI tools" : "Scan Mail downloads",
                           symbol: ai ? "sparkles" : "paperclip",
                           message: ai ? "Scan to see what can be reviewed for cleanup."
                               : "Scan to find matching downloads. Keep your changes and any download with an unverified original.")
            }
        }
        .task(id: refresh) {
            guard refresh > 0 else { return }
            scanning = true
            selected = []
            let control = ScanControl { _ in }
            let found = await withTaskCancellationHandler {
                await model.removal.scanTool(tool, control: control)
            } onCancel: { control.cancel() }
            guard !Task.isCancelled else { return }
            review = found
            scanning = false
        }
        .sheet(isPresented: $showModels, onDismiss: {
            if let modelConfirmation { ui.confirm = modelConfirmation }
            modelConfirmation = nil
        }) {
            OllamaModelsSheet(home: model.scanHome, removal: model.removal) { summary in
                modelConfirmation = summary
                showModels = false
            }
        }
        .quickLookPreview($preview)
        .onChange(of: ui.receiptShowing) { _, shown in
            if !shown, review != nil { refresh += 1 }
        }
    }

    private var models: some View {
        InsetGroup {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Ollama").font(.headline)
                    Text("See each model’s size and the files it shares with other models.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("View Models…") { showModels = true }
            }.groupRow()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LM Studio").font(.headline)
                    Text("Scan to review individual GGUF files in the default store. Open My Models for other formats or custom folders.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "ai.elementlabs.lmstudio") {
                    Button("Open LM Studio") { NSWorkspace.shared.open(app) }
                } else {
                    Link("Model Storage Guide", destination: URL(string: "https://lmstudio.ai/docs/app/basics/download-model")!)
                }
            }.groupRow()
        }
    }

    @ViewBuilder private func results(_ review: ToolCleanup.Review) -> some View {
        if review.incomplete {
            Banner(text: "Some locations couldn’t be read. The results may be incomplete.",
                   symbol: "exclamationmark.circle", tint: .orange)
        }
        if review.preserved > 0 {
            Text(ai ? "\(review.preserved.formatted()) locations could not be safely reviewed."
                 : "\(review.preserved.formatted()) downloads were kept because an identical Mail copy couldn’t be verified.")
                .font(.callout).foregroundStyle(.secondary)
        }
        if review.items.isEmpty {
            EmptyState(title: "No items to review", symbol: "checkmark.circle",
                       message: ai ? "There are no eligible caches or logs in the locations checked."
                           : "Only downloads with a verified matching copy appear here.")
        } else {
            HStack {
                TextField("Search Results", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 270)
                Button(ai ? "Select Shown Caches and Logs" : "Select Shown") {
                    selected.formUnion(visible.filter { !$0.isLocalModel }.map(\.id))
                }
                .disabled(!visible.contains { !$0.isLocalModel })
                Spacer()
                Button("Review Selected…") {
                    ui.confirm = model.removal.prepareToolCleanup(review.items, selected: selected)
                    if ui.confirm == nil { ui.problem = "These items couldn’t be reviewed. Scan again to refresh the results." }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || model.removal.isExecuting || model.removal.removalDisabledReason != nil)
            }
            if visible.isEmpty { Text("No matching items.").foregroundStyle(.secondary) }
            LazyInsetList(items: visible) { item in
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                        if value { selected.insert(item.id) } else { selected.remove(item.id) }
                    })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).fontWeight(.medium)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(ByteFormat.string(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                    Menu("Item Actions", systemImage: "ellipsis.circle") {
                        if !ai { Button("Quick Look") { preview = item.url } }
                        Button("Show in Finder") { model.reveal(item.url) }
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }.groupRow()
            }
        }
    }
}
