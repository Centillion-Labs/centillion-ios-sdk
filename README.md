# Centillion iOS SDK

A headless Swift 6 client for iOS 17+ and macOS 14+. Use SwiftUI or UIKit for your chat interface. All public client methods and callbacks run on the main actor.

## Install and run

In Xcode, choose File → Add Package Dependencies and enter:

```text
https://github.com/Centillion-Labs/centillion-ios-sdk.git
```

Select version **0.1.0** or later and add **CentillionSDK** to your app target. For another Swift package:

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/Centillion-Labs/centillion-ios-sdk.git", from: "0.1.0")
]
// In your target's dependencies:
// .product(name: "CentillionSDK", package: "centillion-ios-sdk")
```

The [iOS example app](https://github.com/Centillion-Labs/ios-sdk-example-app) is a separate public repository. Clone it, open `CentillionSample.xcodeproj`, select an iPhone simulator, and run. Xcode resolves the SDK from this repository. Enter your agent ID and SDK base URL, such as `https://app.cntillion.com/api/sdk`. Enable iOS SDK Visibility in the dashboard first. The example has streaming messages, history, pagination, retry, a new conversation button, and a `get_app_version` tool handler.

For local development the iOS simulator can use `http://localhost:3000/api/sdk`. HTTP is accepted only for loopback hosts. On a physical device use an HTTPS development URL. The sample's local networking allowance is confined to its Debug configuration.

## Client and streaming

```swift
import CentillionSDK

@MainActor func example() async throws {
    let client = CentillionClient(agentId: "YOUR_AGENT_ID", baseURL: "https://your-centillion-host/api/sdk")
    let answer = try await client.send("Hello!") { callbacks in
        callbacks.onTextDelta = { delta in print(delta, terminator: "") }
        callbacks.onToolCall = { call in print("Running", call.name) }
        callbacks.onToolResult = { result in print(result.output) }
    }
    // Supply the ID to continue. Omitting it starts a new conversation on iOS.
    _ = try await client.send("Tell me more", conversationId: answer.conversationId)
}
```

`sendNonStreaming` returns the final `ChatResponse` without delta callbacks. It consumes the same stream internally, including native tools. `retry(conversationId:messageId:configure:)` regenerates an assistant answer and removes later messages only after the replacement succeeds. Failed retries keep the saved transcript intact. Cancel the calling Swift Task to cancel the request; external actions already executed cannot be undone.

`ChatResponse` contains `message`, `conversationId`, `userMessageId`, `finishReason`, and optional `usage` with `credits`, `inputTokens`, and `outputTokens`. A `Message` contains `id`, `role`, `text`, `createdAt`, optional `feedback`, `confidence`, `presentation`, and ordered `parts` for text, tool calls, and tool results. `text` joins the text from all model rounds. Presentations are data for your interface; the SDK does not render web widgets.

## Observable state

```swift
@State private var conversation: ConversationState
// Initialize in your view's init:
_conversation = State(initialValue: ConversationState(client: client))
// In a Task:
await conversation.sendMessage("Hello")
```

Observe `messages`, `conversationId`, `isSending`, `isLoadingHistory`, `hasMoreHistory`, `toolCalls`, `toolResults`, and `error`. Methods are `sendMessage`, `retry(messageId:)`, `loadHistory(conversationId:limit:)`, `loadMoreHistory`, `clearError`, and `clear`. A state holder continues its current conversation automatically. `clear()` resets its local state. Cancel outstanding Tasks before switching accounts and clear both state holders after identify/logout.

`ConversationListState` exposes `conversations`, `isLoading`, `hasMore`, and `error`. Call `load(limit:)`, `loadMore()`, `clearError()`, or `clear()`.

## History and pagination

```swift
let conversations = try await client.listConversations(limit: 20)
let messages = try await client.listMessages(conversationId: id, limit: 20)
if messages.hasMore, let cursor = messages.cursor {
    let older = try await client.listMessages(conversationId: id, cursor: cursor, limit: 20)
    // Prepend older.data to messages.data.
}
```

Pages have `data`, `total`, `hasMore`, and `cursor`. Limits are 1–100. Conversation pages are ordered by latest activity. The first message page contains the newest messages in chronological order. Later pages contain older messages, also chronological. Concurrent new activity may move items between conversation pages; state holders deduplicate by ID.

History includes this agent's iOS and Android SDK conversations only. Anonymous history belongs to the app installation. Identified users share mobile history across devices and platforms. Website conversations are excluded. Conversation `status` is `ongoing`, `taken_over`, or `ended`; paused or ended conversations cannot accept messages or retries.

## Identity

The SDK generates a stable installation UUID per agent and base URL. Get a short-lived HS256 JWT from your authenticated backend, then call:

```swift
try await client.identify(token: jwt)
print(client.isIdentified, client.currentUserId as Any)
client.logout()
```

Use the agent's identity secret from Settings → Identity verification on your backend only. JWT claims require `sub` or `user_id` and `exp`, at most 24 hours ahead. Optional `name`, `email`, and `phone` become verified contact fields. Refresh expired tokens with `identify`. Invalid or expired tokens reject with `INVALID_IDENTITY`; they never silently fall back to anonymous access.

Successful identify merges this installation's anonymous mobile conversations into that user and resets the current conversation. Logout clears the Keychain token and current conversation, while retaining the installation ID. It does not delete saved server history. The JWT is stored in Keychain using device-only protection. `currentUserId` is populated by identify; after restoring a Keychain token, call identify again if your app needs that property. Clear cached UI state on account changes.

## Native tools

Create a custom **Client action** in the dashboard, name it `get_app_version`, enable it on iOS SDK, and turn on Wait for response. Register the exact action name:

```swift
client.tool("get_app_version") { input in
    .object(["version": .string("1.0.0")])
}
client.removeTool("get_app_version")
```

Handlers receive and return `JSONValue`, which supports strings, numbers, booleans, arrays, objects, and null. The SDK calls the handler, posts the result, and continues the model turn. Unknown handlers and thrown errors return a safe error to the agent. Outputs must be valid JSON and no more than 20,000 UTF-8 bytes. The automatic handler limit is 10 calls per turn, configurable with `maxToolLoopSteps`. Server generation has its own step/time limits. Native actions must finish within the server's 25-second callback window.

Server API actions execute on Centillion and need no device handler. Observe both native and server calls with `onToolCall` and `onToolResult`. Server calls have `execution == "server"`. Only actions enabled for the requesting platform are available, even when resuming a conversation originally created on the other platform. JavaScript client code is not executed by a native SDK. Implement that action in Swift. HTML widgets, forms, and buttons require your own native presentation UI.

## Feedback and errors

```swift
try await client.feedback(conversationId: id, messageId: answerId, value: "up")
try await client.feedback(conversationId: id, messageId: answerId, value: nil) // clear
```

Catch `SDKError` for server errors and inspect `status`, `code`, and `message`. Transport failures use URLSession's errors; cancellation uses `CancellationError` or URLSession cancellation. Handle `INVALID_IDENTITY` by refreshing the JWT, `AGENT_NOT_FOUND` by checking Visibility and the ID, `CONVERSATION_NOT_FOUND` by starting or selecting an owned conversation, and `CONVERSATION_CHANGED` by reloading history. `INCOMPLETE_STREAM` means the stream ended without a final response. Show an error and let the user retry; the library never silently resends a message that might execute an action twice.

## Verify

```sh
swift test
```

See the example repository for the simulator build command. For a live smoke run, launch the example with `-agentId YOUR_ID -baseURL http://localhost:3000/api/sdk -smoke YES`. Configure the `get_app_version` action first. The run checks live reply, history pagination, retry, and native tool execution, then writes `Documents/sdk-smoke.txt` in the app container. Use a dedicated test agent because this creates real conversations and consumes reply credits.
