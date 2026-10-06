import Foundation

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Double.self) { self = .number(number) }
        else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let object = try? value.decode([String: JSONValue].self) { self = .object(object) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .string(let v): try value.encode(v)
        case .number(let v): try value.encode(v)
        case .bool(let v): try value.encode(v)
        case .object(let v): try value.encode(v)
        case .array(let v): try value.encode(v)
        case .null: try value.encodeNil()
        }
    }
    public subscript(key: String) -> JSONValue? { if case .object(let value) = self { return value[key] }; return nil }
    public var stringValue: String? { if case .string(let value) = self { return value }; return nil }
    public var numberValue: Double? { if case .number(let value) = self { return value }; return nil }
    public var boolValue: Bool? { if case .bool(let value) = self { return value }; return nil }
}

public struct Message: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let role: String
    public var text: String
    public let createdAt: String
    public var feedback: String?
    public let confidence: Double?
    public let presentation: JSONValue?
    public var parts: [MessagePart]?
    public init(id: String, role: String, text: String, createdAt: String = ISO8601DateFormatter().string(from: Date()), feedback: String? = nil, confidence: Double? = nil, presentation: JSONValue? = nil) {
        self.id = id; self.role = role; self.text = text; self.createdAt = createdAt
        self.feedback = feedback; self.confidence = confidence; self.presentation = presentation
    }
}
public struct Conversation: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let createdAt: String
    public let updatedAt: String
    public let userId: String?
    public let status: String
}
public struct ChatResponse: Codable, Sendable {
    public let message: Message
    public let conversationId: String
    public let userMessageId: String
    public let finishReason: String
    public let usage: Usage?
}
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    public let data: [Item]
    public let total: Int
    public let hasMore: Bool
    public let cursor: String?
}
public struct ToolCall: Decodable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let input: JSONValue
    public let execution: String?
}
public struct ToolResult: Sendable {
    public let call: ToolCall
    public let output: JSONValue
}
public struct StreamCallbacks {
    public var onTextDelta: (@MainActor (String) async -> Void)?
    public var onToolCall: (@MainActor (ToolCall) async -> Void)?
    public var onToolResult: (@MainActor (ToolResult) async -> Void)?
    public init() {}
}
public struct SDKError: Error, LocalizedError, Decodable, Sendable {
    public let status: Int?
    public let code: String
    public let message: String
    public var errorDescription: String? { message }
    public init(status: Int? = nil, code: String, message: String) { self.status = status; self.code = code; self.message = message }
}

public struct Usage: Codable, Sendable {
    public let credits: Int
    public let inputTokens: Int
    public let outputTokens: Int
}
public struct MessagePart: Codable, Sendable, Equatable {
    public let type: String
    public let text: String?
    public let id: String?
    public let name: String?
    public let input: JSONValue?
    public let output: JSONValue?
}
