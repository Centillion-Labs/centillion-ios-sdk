# Mobile HTTP protocol

Base path: `/api/sdk/{agentId}`. All routes require `X-Centillion-Platform: ios|android` and `X-Centillion-Device-ID: <installation UUID>`. Identified requests also require `Authorization: Bearer <HS256 JWT>`. Both platforms use the same protocol. Visibility must be enabled for the requesting platform.

| Method and path | Body / query | Result |
| --- | --- | --- |
| POST chat | requestId UUID, optional conversationId UUID, message up to 12,000 characters, stream true | SSE |
| POST retry | requestId UUID, conversationId UUID, assistant messageId, stream true | SSE |
| POST identify | empty JSON, signed Authorization | userId; merges installation's anonymous mobile history |
| GET conversations | optional cursor, limit 1–100 | data, total, hasMore, cursor |
| GET conversations/{id}/messages | optional cursor, limit 1–100 | public messages only, newest group first |
| POST tool-results | conversationId, requestId, id, output | success |
| POST feedback | conversationId, messageId, feedback up/down/null | success |

Bodies are bounded at 24,000 bytes. Native tool outputs are bounded at 20,000 bytes. Errors before streaming use `{ "error": { "code", "message" } }` with an HTTP error status. Responses are never cached. The native non-streaming helpers consume SSE internally so tools work in both modes; `stream: false` on the wire is rejected.

SSE frames have `data: <JSON>` followed by a blank line:

- `start`: conversationId, requestId, messageId, userMessageId.
- `text-delta`: delta from the model.
- `tool-call`: id, exact registered action name, input JSON. For native calls, post tool-results while keeping this stream open. Ownership, turn ID, expiry, and one-time completion are checked server-side. Server calls have `execution: "server"`; observe them without posting a result.
- `tool-result`: id, name, output JSON, execution server. Native results are observed locally after submission.
- `finish`: message, conversationId, userMessageId, finishReason, usage with credits, inputTokens, and outputTokens. Message `parts` contains ordered text, tool-call, and tool-result records. Message `text` joins all text rounds. Tool IDs in persisted parts correlate model calls with their results; native callback IDs identify pending device invocations.
- `error`: status, code, message. Discard the incomplete assistant response and reload saved history when needed.

A completed request ID may return a cached JSON ChatResponse, which both clients handle. Retain a request ID when explicitly replaying the same HTTP operation. Do not reuse it for different text. SDK calls create new request IDs and never transparently retry potentially side-effecting actions.

Server tool payloads exposed in events and parts are limited to 20,000 UTF-8 bytes. Larger payloads return `{ "truncated": true }`; the model still receives the original result. Model finish reasons, including `stop`, `length`, and `tool-calls`, are preserved. A cached replay consumes zero additional credits.

Conversations are scoped to agent, organization, device or verified user, and mobile source. A user cannot list or resume another user's conversations with a guessed ID. Anonymous identify claims are restricted to unverified conversations from that installation. Identification invalidates in-flight writes. Cross-platform history retains its original source for analytics; model, instructions, and available actions come from the current platform.

Generation uses the shared Centillion reply engine, including retrieval, action configuration, rate limits, credits, and transcript compare-and-swap. Retry claims a revision without truncating the saved transcript, generates from history before the chosen assistant message, and atomically replaces it on success. Failed or superseded writes preserve the previous transcript. Client cancellation propagates to model generation. Actions already dispatched cannot be undone.

Standard SDK codes: INVALID_REQUEST, INVALID_IDENTITY, AGENT_NOT_FOUND, CONVERSATION_NOT_FOUND, CONVERSATION_NOT_ONGOING, CONVERSATION_CHANGED, INVALID_CURSOR, MESSAGE_NOT_FOUND, RATE_LIMITED, CREDIT_LIMIT_REACHED, PROVIDER_ERROR, CHAT_FAILED, TOOL_RESULT_TOO_LARGE, TOOL_CALL_NOT_PENDING, STREAM_REQUIRED. Client-side errors additionally include INCOMPLETE_STREAM, TOOL_LOOP_LIMIT, and INSECURE_URL.
