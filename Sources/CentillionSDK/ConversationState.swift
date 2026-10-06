import Foundation
import Observation

@MainActor @Observable public final class ConversationState {
    public private(set) var messages: [Message] = []
    public private(set) var toolCalls: [ToolCall] = []
    public private(set) var toolResults: [String: JSONValue] = [:]
    public private(set) var conversationId: String?
    public private(set) var isSending = false
    public private(set) var isLoadingHistory = false
    public private(set) var hasMoreHistory = false
    public private(set) var error: Error?
    private let client: CentillionClient
    private var cursor: String?
    private var generation = 0
    private var historyLimit = 20
    public init(client: CentillionClient) { self.client = client }
    public func clearError() { error = nil }
    public func clear() {
        generation += 1; messages = []; toolCalls = []; toolResults = [:]
        conversationId = nil; cursor = nil; hasMoreHistory = false; error = nil
        isSending = false; isLoadingHistory = false; client.newConversation()
    }
    public func sendMessage(_ text: String) async {
        guard !isSending, !isLoadingHistory, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        messages.append(Message(id: UUID().uuidString, role: "user", text: text))
        await perform(text: text)
    }
    public func retry(messageId: String) async {
        guard !isSending, !isLoadingHistory, conversationId != nil, let index = messages.firstIndex(where: { $0.id == messageId && $0.role == "assistant" }) else { return }
        let previous = messages
        let version = generation
        messages = Array(messages.prefix(index))
        await perform(text: "", retryId: messageId)
        if generation == version && error != nil { messages = previous }
    }
    private func perform(text: String, retryId: String? = nil) async {
        isSending = true; error = nil
        let version = generation
        let placeholder = UUID().uuidString
        messages.append(Message(id: placeholder, role: "assistant", text: ""))
        let configure: (inout StreamCallbacks) -> Void = { callbacks in
            callbacks.onTextDelta = { [weak self] delta in
                guard let self, self.generation == version, let index = self.messages.firstIndex(where: { $0.id == placeholder }) else { return }
                self.messages[index].text += delta
            }
            callbacks.onToolCall = { [weak self] call in if self?.generation == version { self?.toolCalls.append(call) } }
            callbacks.onToolResult = { [weak self] result in if self?.generation == version { self?.toolResults[result.call.id] = result.output } }
        }
        do {
            let response: ChatResponse
            if let retryId, let conversationId { response = try await client.retry(conversationId: conversationId, messageId: retryId, configure: configure) }
            else { response = try await client.send(text, conversationId: conversationId, configure: configure) }
            guard generation == version else { return }
            conversationId = response.conversationId
            if let index = messages.firstIndex(where: { $0.id == placeholder }) {
                messages[index] = response.message
                if retryId == nil && index > 0 {
                    let user = messages[index - 1]
                    messages[index - 1] = Message(id: response.userMessageId, role: "user", text: user.text, createdAt: user.createdAt)
                }
            }
        } catch { if generation == version { self.error = error; messages.removeAll { $0.id == placeholder && $0.text.isEmpty } } }
        if generation == version { isSending = false }
    }
    public func loadHistory(conversationId: String, limit: Int = 20) async {
        guard !isSending else { return }
        generation += 1; let version = generation
        isLoadingHistory = true; error = nil
        do {
            let page = try await client.listMessages(conversationId: conversationId, limit: limit)
            guard generation == version else { return }
            self.conversationId = conversationId; messages = page.data; cursor = page.cursor
            hasMoreHistory = page.hasMore; historyLimit = limit; toolCalls = []; toolResults = [:]
        } catch { if generation == version { self.error = error } }
        if generation == version { isLoadingHistory = false }
    }
    public func loadMoreHistory() async {
        guard !isSending, !isLoadingHistory, hasMoreHistory, let conversationId, let cursor else { return }
        let version = generation; isLoadingHistory = true
        do {
            let page = try await client.listMessages(conversationId: conversationId, cursor: cursor, limit: historyLimit)
            guard generation == version else { return }
            let ids = Set(messages.map(\.id))
            messages = page.data.filter { !ids.contains($0.id) } + messages
            self.cursor = page.cursor; hasMoreHistory = page.hasMore
        } catch { if generation == version { self.error = error } }
        if generation == version { isLoadingHistory = false }
    }
}

@MainActor @Observable public final class ConversationListState {
    public private(set) var conversations: [Conversation] = []
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var error: Error?
    private let client: CentillionClient
    private var cursor: String?
    private var limit = 20
    private var generation = 0
    public init(client: CentillionClient) { self.client = client }
    public func clearError() { error = nil }
    public func clear() { generation += 1; conversations = []; cursor = nil; hasMore = false; isLoading = false; error = nil }
    public func load(limit: Int = 20) async { self.limit = limit; await fetch(more: false) }
    public func loadMore() async { guard hasMore else { return }; await fetch(more: true) }
    private func fetch(more: Bool) async {
        guard !isLoading else { return }; isLoading = true; error = nil
        let version = generation
        do {
            let page = try await client.listConversations(cursor: more ? cursor : nil, limit: limit)
            guard version == generation else { return }
            let ids = Set(conversations.map(\.id))
            conversations = more ? conversations + page.data.filter { !ids.contains($0.id) } : page.data
            cursor = page.cursor; hasMore = page.hasMore
        } catch { if version == generation { self.error = error } }
        if version == generation { isLoading = false }
    }
}
