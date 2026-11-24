import AndromedaAppModel
import AndromedaCore
import SwiftUI

public enum ToolPage: Hashable {
    case aiClutter, mailAttachments, trashBins, maintenance, snapshots, downloads, largeFiles, similarImages
}

struct ToolsView: View {
    let model: AppModel
    let ui: UIState

    @State private var appReview: ApplicationCleanupSheet.Mode?
    @State private var appConfirmation: ConfirmSummary?
    @State private var preparing: String?

    var body: some View {
        PageColumn {
            PageHeader(title: "Tools", subtitle: "Find a specific cleanup or maintenance task.", symbol: "wrench.and.screwdriver.fill")
            group("Cleanup") {
                link("AI Clutter", "Review AI app caches, logs, and local models.", "sparkles", .indigo, .aiClutter)
                link("Mail Attachments", "Review local downloads that match a copy in Apple Mail.", "paperclip", .cyan, .mailAttachments)
                link("Trash Bins", "Review items in Trash on your Mac and connected drives.", "trash", .orange, .trashBins)
                card("System Junk", "Review recognised caches, logs, backups, and developer files.", "internaldrive", .teal) {
                    withMacScan("System Junk") { ui.destination = .page(.systemData) }
                }
            }
            group("Apps") {
                card("App Leftovers", "Find Library files from apps you’ve already removed.", "puzzlepiece.extension", .blue) {
                    withMacScan("App Leftovers") { appReview = .leftovers }
                }
                card("Uninstaller", "Review installed apps and their related files before moving them to Trash.", "square.grid.2x2", .indigo) {
                    withMacScan("Uninstaller") { appReview = .installed }
                }
            }
            group("Maintenance") {
                link("Maintenance Tasks", "Run troubleshooting tasks for Spotlight, DNS, your startup disk, and Mail.",
                     "wrench.and.screwdriver", .teal, .maintenance)
                link("Time Machine Snapshots", "Review local restore points on the startup disk.", "clock.arrow.circlepath", .indigo, .snapshots)
            }
            group("Find Files") {
                link("Downloads", "Review files in Downloads and group them by the app that downloaded them.",
                     "arrow.down.circle", .blue, .downloads)
                card("Duplicate Finder", "Compare folders and drives for files with identical contents.", "doc.on.doc", .purple) {
                    ui.destination = .duplicates
                }
                link("Similar Images", "Compare photos that look alike, including resized and re-encoded copies.",
                     "photo.on.rectangle.angled", .pink, .similarImages)
                link("Large and Old Files", "Find space-heavy files you haven’t opened recently.",
                     "folder", .orange, .largeFiles)
            }
        }
        .sheet(item: $appReview, onDismiss: {
            if let appConfirmation { ui.confirm = appConfirmation }
            appConfirmation = nil
        }) { mode in
            ApplicationCleanupSheet(removal: model.removal, mode: mode, cancel: { appReview = nil }) { summary in
                appConfirmation = summary
                appReview = nil
            }
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeading(title: title)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10, content: content)
        }
    }

    private func link(_ title: String, _ detail: String, _ symbol: String, _ tint: Color, _ page: ToolPage) -> some View {
        card(title, detail, symbol, tint) { ui.destination = .tool(page) }
    }

    private func card(_ title: String, _ detail: String, _ symbol: String, _ tint: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                SymbolTile(symbol: symbol, tint: tint, size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if preparing == title {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .padding(.top, 3).accessibilityHidden(true)
                }
            }
            .frame(minHeight: 57, alignment: .topLeading)
            .card(padding: 12)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .disabled(preparing == title)
    }

    private func withMacScan(_ title: String, show: @escaping () -> Void) {
        if model.scan.lastResult != nil { show(); return }
        guard preparing == nil, model.canScan else {
            ui.problem = "You can open this tool after the current storage work finishes."
            return
        }
        preparing = title
        Task {
            await model.scan()
            preparing = nil
            guard ui.destination == .tools else { return }
            if model.scan.lastResult != nil {
                show()
            } else {
                ui.problem = model.scanFailedText ?? "A completed Mac scan is needed to open this tool."
            }
        }
    }
}

struct ToolBackButton: View {
    let ui: UIState

    var body: some View {
        Button("All Tools", systemImage: "chevron.left") { ui.destination = .tools }
    }
}
