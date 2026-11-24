import Foundation

/// The default Ollama service on this Mac. The model revision is checked again just before deletion.
public enum OllamaLocalModels {
    public struct Model: Decodable, Equatable, Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let size: Int64
        public let digest: String

        fileprivate var valid: Bool {
            !name.isEmpty && name.utf8.count <= 256
                && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
                && size > 0 && digest.utf8.count == 64 && digest.allSatisfy { $0.isASCII && $0.isHexDigit }
        }
    }

    private struct Tags: Decodable { let models: [Model] }
    private struct Deletion: Encodable { let model: String }
    private static let endpoint = "http://127.0.0.1:11434/api/"
    private static let curl = URL(fileURLWithPath: "/usr/bin/curl")
    private static let arguments = [
        "--disable", "--noproxy", "*", "--proto", "=http", "--silent", "--show-error",
        "--max-time", "5", "--max-filesize", "4194304", "--write-out", "\n%{http_code}",
    ]

    public static func list(using tools: any ToolRunner) -> [Model]? {
        guard let result = try? tools.run(curl, arguments + ["--url", endpoint + "tags"]),
              let body = body(result), let tags = try? JSONDecoder().decode(Tags.self, from: Data(body.utf8)) else {
            return nil
        }
        let byName = Dictionary(grouping: tags.models, by: \.name)
        return tags.models.filter { $0.valid && byName[$0.name]?.count == 1 }
            .sorted { $0.size > $1.size }
    }

    public static func plan(_ model: Model) -> RemovalPlan? {
        guard model.valid else { return nil }
        return RemovalPlan(removals: [
            PlannedRemoval(catalogEntryID: "ollama-model-removal", action: .removeOllamaModel(model),
                           expectedBytes: nil, expectation: nil, appsMustBeQuit: []),
        ])
    }

    static func delete(_ model: Model, using tools: any ToolRunner) -> Outcome {
        guard let current = list(using: tools) else { return .failed("The local Ollama service couldn’t be reached.") }
        guard current.contains(model) else { return .skipped(.changedSinceScan) }
        guard let data = try? JSONEncoder().encode(Deletion(model: model.name)),
              let result = try? tools.run(curl, arguments + [
                "--request", "DELETE", "--header", "Content-Type: application/json",
                "--data-binary", String(decoding: data, as: UTF8.self), "--url", endpoint + "delete",
              ]), body(result) != nil else { return .failed("Couldn’t confirm removal. Refresh the list in Ollama to check the model.") }
        return .done
    }

    private static func body(_ response: ToolResult) -> Substring? {
        guard response.exitCode == 0, let end = response.stdout.lastIndex(of: "\n"),
              response.stdout[response.stdout.index(after: end)...] == "200" else { return nil }
        return response.stdout[..<end]
    }
}
