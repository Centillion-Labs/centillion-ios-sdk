import Foundation
import Security

/// Create one client per agent. All callbacks and state changes run on the main actor.
@MainActor public final class CentillionClient {
    public let agentId: String
    public let deviceId: String
    public private(set) var currentConversationId: String?
    public private(set) var currentUserId: String?
    public var isIdentified: Bool { token != nil }
    public let maxToolLoopSteps: Int
    private let baseURL: String
    private let session: URLSession
    private let account: String
    private var token: String?
    private var identityRevision = 0
    private var tools: [String: @MainActor (JSONValue) async throws -> JSONValue] = [:]

    public init(agentId: String, baseURL: String, configuration: URLSessionConfiguration = .default, maxToolLoopSteps: Int = 10) {
        self.agentId = agentId
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.account = "\(baseURL)|\(agentId)"
        self.maxToolLoopSteps = max(1, maxToolLoopSteps)
        session = URLSession(configuration: configuration)
        let key = "centillion.device.\(account)"
        let stored = UserDefaults.standard.string(forKey: key)
        deviceId = stored.flatMap { UUID(uuidString: $0)?.uuidString } ?? UUID().uuidString
        UserDefaults.standard.set(deviceId, forKey: key)
        var result: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.centillion.sdk", kSecAttrAccount as String: account, kSecReturnData as String: true]
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data {
            token = String(data: data, encoding: .utf8)
        }
    }

    public func tool(_ name: String, handler: @escaping @MainActor (JSONValue) async throws -> JSONValue) { tools[name] = handler }
    public func removeTool(_ name: String) { tools.removeValue(forKey: name) }
    public func newConversation() { identityRevision += 1; currentConversationId = nil }

    public func identify(token newToken: String) async throws {
        let revision = identityRevision
        let response: IdentityResponse = try await json("identify", body: .object([:]), tokenOverride: newToken)
        guard revision == identityRevision else { throw CancellationError() }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.centillion.sdk", kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(newToken.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw SDKError(code: "IDENTITY_STORAGE_FAILED", message: "Could not save the identity securely.") }
        } else if status != errSecSuccess { throw SDKError(code: "IDENTITY_STORAGE_FAILED", message: "Could not save the identity securely.") }
        token = newToken; currentUserId = response.userId; currentConversationId = nil; identityRevision += 1
    }

    public func logout() {
        identityRevision += 1; token = nil; currentUserId = nil; currentConversationId = nil
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.centillion.sdk", kSecAttrAccount as String: account] as CFDictionary)
    }

    public func send(_ message: String, conversationId: String? = nil, configure: (inout StreamCallbacks) -> Void = { _ in }) async throws -> ChatResponse {
        try await stream("chat", body: sendBody(message, conversationId: conversationId), configure: configure)
    }
    public func retry(conversationId: String, messageId: String, configure: (inout StreamCallbacks) -> Void = { _ in }) async throws -> ChatResponse {
        try await stream("retry", body: ["requestId": .string(UUID().uuidString), "conversationId": .string(conversationId), "messageId": .string(messageId), "stream": .bool(true)], configure: configure)
    }
    public func sendNonStreaming(_ message: String, conversationId: String? = nil) async throws -> ChatResponse {
        try await send(message, conversationId: conversationId)
    }
    public func listConversations(cursor: String? = nil, limit: Int = 20) async throws -> Page<Conversation> {
        try await json("conversations", query: pageQuery(cursor, limit))
    }
    public func listMessages(conversationId: String, cursor: String? = nil, limit: Int = 20) async throws -> Page<Message> {
        try await json("conversations/\(segment(conversationId))/messages", query: pageQuery(cursor, limit))
    }
    public func feedback(conversationId: String, messageId: String, value: String?) async throws {
        let _: SuccessResponse = try await json("feedback", body: .object(["conversationId": .string(conversationId), "messageId": .string(messageId), "feedback": value.map(JSONValue.string) ?? .null]))
    }

    private func sendBody(_ message: String, conversationId: String?) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["requestId": .string(UUID().uuidString), "message": .string(message), "stream": .bool(true)]
        if let conversationId { value["conversationId"] = .string(conversationId) }
        return value
    }
    private func pageQuery(_ cursor: String?, _ limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "limit", value: String(limit))] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
    }
    private func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "" }
    private func request(_ path: String, body: JSONValue? = nil, query: [URLQueryItem] = [], tokenOverride: String? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: "\(baseURL)/\(segment(agentId))/\(path)"), ["https", "http"].contains(components.scheme ?? "") else {
            throw SDKError(code: "INVALID_URL", message: "Provide a valid SDK base URL.")
        }
        guard components.scheme == "https" || ["localhost", "127.0.0.1", "::1"].contains(components.host ?? "") else {
            throw SDKError(code: "INSECURE_URL", message: "Use HTTPS for a remote SDK server.")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw SDKError(code: "INVALID_URL", message: "Provide a valid SDK base URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("ios", forHTTPHeaderField: "X-Centillion-Platform")
        request.setValue(deviceId, forHTTPHeaderField: "X-Centillion-Device-ID")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Centillion-iOS/0.1.0", forHTTPHeaderField: "User-Agent")
        if let token = tokenOverride ?? token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        return request
    }
    private func json<T: Decodable & Sendable>(_ path: String, body: JSONValue? = nil, query: [URLQueryItem] = [], tokenOverride: String? = nil) async throws -> T {
        let revision = identityRevision
        let (data, response) = try await session.data(for: request(path, body: body, query: query, tokenOverride: tokenOverride))
        guard revision == identityRevision else { throw CancellationError() }
        try check(response, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw SDKError(code: "INVALID_RESPONSE", message: "The server returned an invalid response.") }
        if !(200..<300).contains(http.statusCode) {
            let error = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw SDKError(status: http.statusCode, code: error?.error.code ?? "REQUEST_FAILED", message: error?.error.message ?? "The SDK request failed.")
        }
    }

    private func stream(_ path: String, body: [String: JSONValue], configure: (inout StreamCallbacks) -> Void) async throws -> ChatResponse {
        var callbacks = StreamCallbacks(); configure(&callbacks)
        let revision = identityRevision
        let (bytes, response) = try await session.bytes(for: request(path, body: .object(body)))
        guard let http = response as? HTTPURLResponse else { throw SDKError(code: "INVALID_RESPONSE", message: "The server returned an invalid response.") }
        if !(200..<300).contains(http.statusCode) || http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true {
            var data = Data(); for try await byte in bytes { data.append(byte); if data.count > 1_000_000 { break } }
            try check(response, data: data)
            guard revision == identityRevision else { throw CancellationError() }
            let result = try JSONDecoder().decode(ChatResponse.self, from: data)
            currentConversationId = result.conversationId
            return result
        }
        var conversationId: String?
        var toolCount = 0
        var observedCalls: [String: ToolCall] = [:]
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard revision == identityRevision else { throw CancellationError() }
            guard line.hasPrefix("data: ") else { continue }
            let eventData = Data(line.dropFirst(6).utf8)
            let event = try JSONDecoder().decode(JSONValue.self, from: eventData)
            switch event["type"]?.stringValue {
            case "start": conversationId = event["conversationId"]?.stringValue
            case "text-delta": if let delta = event["delta"]?.stringValue { await callbacks.onTextDelta?(delta) }
            case "tool-call":
                let call = try JSONDecoder().decode(ToolCall.self, from: eventData)
                observedCalls[call.id] = call
                await callbacks.onToolCall?(call)
                guard revision == identityRevision else { throw CancellationError() }
                if event["execution"]?.stringValue == "server" { continue }
                toolCount += 1
                guard toolCount <= maxToolLoopSteps else { throw SDKError(code: "TOOL_LOOP_LIMIT", message: "The agent requested too many tool calls.") }
                let output: JSONValue
                do {
                    if let handler = tools[call.name] { output = try await handler(call.input) }
                    else { output = .object(["error": .string("No handler is registered for this tool.")]) }
                } catch is CancellationError { throw CancellationError() }
                catch { output = .object(["error": .string("The app could not complete this action.")]) }
                guard revision == identityRevision else { throw CancellationError() }
                guard let conversationId else { throw SDKError(code: "INVALID_RESPONSE", message: "The tool call has no conversation.") }
                let resultData = try JSONEncoder().encode(output)
                guard resultData.count <= 20_000 else { throw SDKError(code: "TOOL_RESULT_TOO_LARGE", message: "Tool results must be no larger than 20 KB.") }
                let _: SuccessResponse = try await json("tool-results", body: .object(["conversationId": .string(conversationId), "requestId": body["requestId"] ?? .null, "id": .string(call.id), "output": output]))
                await callbacks.onToolResult?(ToolResult(call: call, output: output))
            case "tool-result":
                if let id = event["id"]?.stringValue, let call = observedCalls[id], let output = event["output"] {
                    await callbacks.onToolResult?(ToolResult(call: call, output: output))
                }
            case "finish":
                let result = try JSONDecoder().decode(ChatResponse.self, from: eventData)
                currentConversationId = result.conversationId
                return result
            case "error": throw SDKError(status: event["status"]?.numberValue.map(Int.init), code: event["code"]?.stringValue ?? "CHAT_FAILED", message: event["message"]?.stringValue ?? "The reply failed.")
            default: break
            }
        }
        throw SDKError(code: "INCOMPLETE_STREAM", message: "The connection ended before the reply finished.")
    }
}

private struct IdentityResponse: Decodable, Sendable { let userId: String }
private struct SuccessResponse: Decodable, Sendable { let success: Bool }
private struct ErrorResponse: Decodable { let error: SDKError }
