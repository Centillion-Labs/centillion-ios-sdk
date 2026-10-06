import Foundation
import Testing
@testable import CentillionSDK

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var respond: ((URLRequest) throws -> (Int, String))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, body) = try Self.respond!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": body.hasPrefix("data: ") ? "text/event-stream" : "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct ClientTests {
    func client(_ agent: String = "test-agent") -> CentillionClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return CentillionClient(agentId: agent, baseURL: "https://sdk.example/api/sdk", configuration: config)
    }
    @Test func installationIdentityIsStableAndScoped() {
        let first = client()
        #expect(first.deviceId == client().deviceId)
        #expect(first.deviceId != client("different-agent").deviceId)
        #expect(UUID(uuidString: first.deviceId) != nil)
    }
    @Test func historyUsesScopedHeadersAndCursor() async throws {
        StubProtocol.respond = { request in
            #expect(request.value(forHTTPHeaderField: "X-Centillion-Platform") == "ios")
            #expect(request.value(forHTTPHeaderField: "X-Centillion-Device-ID") != nil)
            #expect(request.url?.path == "/api/sdk/test-agent/conversations/test/messages")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "cursor", value: "older+page")) == true)
            return (200, #"{"data":[{"id":"a","role":"assistant","text":"Hi","createdAt":"2026-01-01T00:00:00Z"}],"total":2,"hasMore":true,"cursor":"a"}"#)
        }
        let page = try await client().listMessages(conversationId: "test", cursor: "older+page", limit: 1)
        #expect(page.data.first?.text == "Hi")
        #expect(page.hasMore && page.total == 2)
    }
    @Test func invalidIdentityDoesNotLogIn() async throws {
        StubProtocol.respond = { _ in (401, #"{"error":{"code":"INVALID_IDENTITY","message":"Expired"}}"#) }
        let client = client(UUID().uuidString)
        do { try await client.identify(token: "invalid"); Issue.record("Expected rejection") }
        catch let error as SDKError { #expect(error.status == 401); #expect(error.code == "INVALID_IDENTITY") }
        #expect(!client.isIdentified)
    }
    @Test func jsonRoundTripsNestedToolOutput() throws {
        let value: JSONValue = .object(["count": .number(2), "items": .array([.bool(true), .null, .string("✓")])])
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)) == value)
    }
    @Test func serverToolEventsDoNotInvokeNativeHandlers() async throws {
        StubProtocol.respond = { request in
            #expect(request.url?.path.hasSuffix("/chat") == true)
            return (200, """
            data: {"type":"start","conversationId":"conversation","requestId":"request"}

            data: {"type":"tool-call","execution":"server","id":"lookup-call","name":"lookup","input":{"id":2}}

            data: {"type":"tool-result","id":"lookup-call","name":"lookup","output":{"found":true}}

            data: {"type":"text-delta","delta":"Found it"}

            data: {"type":"finish","conversationId":"conversation","userMessageId":"user","finishReason":"length","usage":{"credits":1,"inputTokens":20,"outputTokens":5},"message":{"id":"answer","role":"assistant","text":"Found it","createdAt":"2026-01-01T00:00:00Z","parts":[{"type":"tool-call","id":"lookup-call","name":"lookup","input":{"id":2}},{"type":"tool-result","id":"lookup-call","name":"lookup","output":{"found":true}},{"type":"text","text":"Found it"}]}}

            """)
        }
        let client = client()
        client.tool("lookup") { _ in Issue.record("Server tool must not run on the device"); return .null }
        var events: [String] = []
        let result = try await client.send("Look it up") { callbacks in
            callbacks.onToolCall = { call in #expect(call.execution == "server"); events.append(call.id) }
            callbacks.onToolResult = { result in #expect(result.output["found"]?.boolValue == true); events.append(result.call.id) }
        }
        #expect(events == ["lookup-call", "lookup-call"])
        #expect(result.finishReason == "length")
        #expect(result.usage?.inputTokens == 20)
        #expect(result.message.parts?.count == 3)
    }
    @Test func incompleteStreamFails() async throws {
        StubProtocol.respond = { _ in (200, "data: {\"type\":\"text-delta\",\"delta\":\"Partial\"}\n\n") }
        do { _ = try await client().send("Hello"); Issue.record("Expected an incomplete stream error") }
        catch let error as SDKError { #expect(error.code == "INCOMPLETE_STREAM") }
    }
    @Test func logoutDuringToolCallbackDoesNotExecuteDeviceAction() async throws {
        StubProtocol.respond = { _ in (200, "data: {\"type\":\"tool-call\",\"id\":\"call\",\"name\":\"version\",\"input\":{}}\n\n") }
        let client = client()
        client.tool("version") { _ in Issue.record("Do not run a device action after logout"); return .null }
        do {
            _ = try await client.send("Version?") { callbacks in callbacks.onToolCall = { _ in client.logout() } }
            Issue.record("Expected cancellation")
        } catch is CancellationError { }
    }
}
