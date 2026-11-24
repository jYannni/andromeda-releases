import AndromedaAppModel
import AndromedaCore
import SwiftUI

struct OllamaModelsSheet: View {
    let home: URL
    var removal: RemovalFlow? = nil
    var onReview: ((ConfirmSummary) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var result: OllamaModelInventory.Result?
    @State private var refresh = 0
    @State private var serviceModels: [OllamaLocalModels.Model]?
    @State private var checkedService = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ollama Models").font(.title2.bold())
            Text("Models in the default Ollama folder. Shared files are counted separately below.")
                .foregroundStyle(.secondary)

            if let result {
                if result.models.isEmpty {
                    Text(result.incomplete ? "The model list could not be read." : "No models found.")
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(result.models) { model in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(model.id).fontWeight(.medium).textSelection(.enabled)
                                    Spacer()
                                    VStack(alignment: .trailing, spacing: 3) {
                                        Text(ByteFormat.string(model.allocatedBytes)).monospacedDigit()
                                        if model.sharedBytes > 0 {
                                            Text("\(ByteFormat.string(model.sharedBytes)) shared")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        if model.unreadableBlobs > 0 {
                                            Text("Partial size").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                    }
                    .frame(minHeight: 100, maxHeight: 340)
                    Text("Shared files count toward each model that uses them. The sizes describe files on disk. Actual space freed can differ.")
                        .font(.callout).foregroundStyle(.secondary)
                    if result.incomplete {
                        Label("Some model files could not be measured. Sizes and sharing may be incomplete.",
                              systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView("Reading local models…").controlSize(.small)
            }

            if let removal, let onReview {
                Divider()
                Text("Running Ollama Service").font(.headline)
                if let serviceModels, !serviceModels.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(serviceModels) { model in
                                HStack {
                                    Text(model.name).lineLimit(1).help(model.name)
                                    Spacer()
                                    Text(ByteFormat.string(model.size)).monospacedDigit().foregroundStyle(.secondary)
                                    Button("Review Removal…") {
                                        if let summary = removal.prepareOllamaRemoval(model) { onReview(summary) }
                                    }
                                    .disabled(removal.isExecuting || removal.removalDisabledReason != nil)
                                }
                            }
                        }
                    }
                    .frame(minHeight: 45, maxHeight: 170)
                } else if checkedService {
                    Text(serviceModels == nil ? "Open Ollama on this Mac, then refresh to review removals."
                         : "Ollama has no downloaded models to review.")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    ProgressView("Checking the local Ollama service…").controlSize(.small)
                }
            }

            HStack {
                Button("Refresh") { refresh += 1 }.disabled(result == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 490)
        .task(id: refresh) {
            result = nil
            let control = ScanControl { _ in }
            let scan = Task.detached(priority: .userInitiated) {
                OllamaModelInventory.scan(home: home, control: control)
            }
            let measured = await withTaskCancellationHandler {
                await scan.value
            } onCancel: {
                control.cancel()
            }
            if !Task.isCancelled { result = measured }
        }
        .task(id: refresh) {
            guard let removal else { return }
            checkedService = false
            serviceModels = nil
            let models = await removal.listOllamaModels()
            guard !Task.isCancelled else { return }
            serviceModels = models
            checkedService = true
        }
    }
}
