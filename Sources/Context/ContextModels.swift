import Foundation

// MARK: - Key-Value

struct ContextKVEntry: Codable, Sendable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let value: String
    let category: String
    let tags: [String]
    let createdBy: String
    let updatedBy: String?
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case key, value, category, tags
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Document

struct ContextDocument: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let body: String
    let category: String
    let tags: [String]
    let createdBy: String
    let updatedBy: String?
    let lineAuthors: [String]?
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, title, body, category, tags
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case lineAuthors = "line_authors"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Knowledge Graph

struct ContextEntity: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let type: String
    let name: String
    let properties: [String: AnyCodable]
    let createdBy: String?
    let updatedBy: String?
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, type, name, properties
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

struct ContextEdge: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let sourceId: String
    let targetId: String
    let relation: String
    let properties: [String: AnyCodable]
    let createdBy: String?
    let updatedBy: String?
    let createdAt: Int64
    let updatedAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, relation, properties
        case sourceId = "source_id"
        case targetId = "target_id"
        case createdBy = "created_by"
        case updatedBy = "updated_by"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }
}

// MARK: - Project

struct ContextProject: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let createdBy: String?
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name
        case createdBy = "created_by"
        case createdAt = "created_at"
    }
}

// MARK: - User

struct ContextUser: Codable, Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let role: String
    let email: String
    let createdAt: Int64

    enum CodingKeys: String, CodingKey {
        case id, name, role, email
        case createdAt = "created_at"
    }
}

// MARK: - Event

struct ContextEvent: Codable, Sendable, Equatable, Identifiable {
    let id: Int64
    let ts: Int64
    let userId: String
    let action: String
    let kind: String
    let targetId: String
    let summary: String

    enum CodingKeys: String, CodingKey {
        case id, ts, action, kind, summary
        case userId = "user_id"
        case targetId = "target_id"
    }
}

// MARK: - Lock

struct ContextLock: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(projectId ?? ""):\(kind):\(targetId)" }
    let projectId: String?
    let kind: String
    let targetId: String
    let userId: String
    let userName: String
    let expiresAt: Int64

    enum CodingKeys: String, CodingKey {
        case kind
        case projectId = "project_id"
        case targetId = "target_id"
        case userId = "user_id"
        case userName = "user_name"
        case expiresAt = "expires_at"
    }
}

// MARK: - Search Result

struct ContextSearchResult: Codable, Sendable, Equatable, Identifiable {
    var id: String { "\(type):\(resultId)" }
    let type: String
    let resultId: String
    let title: String
    let snippet: String
    let score: Int

    enum CodingKeys: String, CodingKey {
        case type
        case resultId = "id"
        case title, snippet, score
    }
}

// MARK: - AnyCodable (lightweight wrapper for JSON any values)

struct AnyCodable: Codable, Sendable, Equatable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        // Simplified equality: compare JSON representations
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let lhsData = try? encoder.encode(lhs),
              let rhsData = try? encoder.encode(rhs) else {
            return false
        }
        return lhsData == rhsData
    }
}
