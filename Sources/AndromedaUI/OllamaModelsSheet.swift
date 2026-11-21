import AndromedaCore
import SwiftUI

struct OllamaModelsSheet: View {
    let home: URL
    @Environment(\.dismiss) private var dismiss
    @State private var result: OllamaModelInventory.Result?
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ollama Models").font(.title2.bold())
            Text("Models in the default Ollama folder. Use Ollama to remove a model.")
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
    }
}
