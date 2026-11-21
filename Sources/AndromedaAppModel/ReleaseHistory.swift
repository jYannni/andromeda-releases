import Foundation

public struct ReleaseHistoryEntry: Decodable, Identifiable, Sendable {
    public struct Section: Decodable, Identifiable, Sendable {
        public let title: String
        public let items: [String]
        public var id: String { title }
    }

    public let version: String
    public let date: Date
    public let sections: [Section]
    public var id: String { version }

    public static func bundled() throws -> [Self] {
        guard let url = Bundle.module.url(forResource: "Releases", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let date = try decoder.singleValueContainer().decode(String.self)
            return try Date.ISO8601FormatStyle().parse(date + "T12:00:00Z")
        }
        return try decoder.decode([Self].self, from: Data(contentsOf: url))
    }
}
