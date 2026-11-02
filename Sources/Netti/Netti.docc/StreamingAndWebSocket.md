# Streaming & WebSocket

Consume a response body as it arrives, as bytes, lines or Server-Sent Events, and talk over a WebSocket.

## Overview

``Netti/stream(_:query:)`` sends a `GET` and returns as soon as the response headers arrive. ``Netti/webSocket(_:pingInterval:)`` opens a WebSocket and returns a ``WebSocketConnection`` actor. Both use the endpoint's headers, the client's interceptors and the engine's server trust policy.

### Stream Server-Sent Events

```swift
let response = try await netti.stream(FeedAPI.live)
for try await event in response.serverSentEvents {
    handle(event.data)
}
```

Each ``ServerSentEvent`` has the `event` type (`nil` for the default `message`), the `data` lines joined by `\n`, the last event `id`, and the `retry` delay the server asked for. The parser follows the WHATWG event-stream rules: a blank line dispatches an event, a line starting with `:` is a comment, and an incomplete event at the end of the stream is dropped.

### Stream lines or bytes

``HTTPStreamResponse`` offers three views of the same body. Iterate only one of them:

- ``HTTPStreamResponse/body``: the raw `Data` chunks as they arrive.
- ``HTTPStreamResponse/lines``: text lines split on LF and CRLF. A line split across chunks arrives whole.
- ``HTTPStreamResponse/serverSentEvents``: parsed `text/event-stream` events.

```swift
for try await line in try await netti.stream(LogAPI.tail).lines {
    handle(line)
}
```

### Stream with another method

For a stream that needs `POST` or a body, build the request and pass it to `stream(_:)`. Interceptors and the client's validation and retry policy apply. There is no endpoint, so no endpoint override does:

```swift
struct Prompt: Encodable, Sendable {
    let text: String
}

var request = try netti.buildRequest(FeedAPI.live, parameters: Prompt(text: "Hello"), method: .post)
request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
for try await event in try await netti.stream(request).serverSentEvents {
    handle(event.data)
}
```

### Errors and cancellation

Interceptors, retry and validation run before the body starts, on the status and headers. Once the body is flowing, a transport failure is thrown from the `for try await` loop and is not retried. Cancelling the consuming task cancels the transfer, and so does breaking out of the loop early and releasing the response.

Streams are not cached, and are never deduplicated.

When a connection closes early while the device is under load, `URLSession` can discard bytes it has read but not yet delivered. The stream then ends or throws as usual, but with fewer bytes than the server sent. Don't treat a stream that ended without an error as proof that every byte arrived; validate the payload when completeness matters.

### Limits

A hostile or broken server can't exhaust memory or time through a stream:

| Limit | Default | On overflow |
|---|---|---|
| One line of ``HTTPStreamResponse/lines`` | 1 MB, without its line break | Throws ``HTTPRequestError/requestFailed(_:)`` with `URLError.dataLengthExceedsMaximum` |
| One event's `data` in ``HTTPStreamResponse/serverSentEvents`` | 1 MB, `data:` lines joined | Same error |
| An event's `retry` | 1 hour | The field is ignored |
| Unread bytes of a stream | 8 MB | Same error |
| Unread WebSocket messages | 1,000 messages or 8 MB | Same error |

Lines are split in time linear in the bytes received, however the server chunks them. For longer lines or events, wrap the body yourself:

```swift
let response = try await netti.stream(FeedAPI.live)
for try await event in ServerSentEventSequence(AsyncLineSequence(response.body), maximumDataLength: 4 * 1_048_576) {
    handle(event.data)
}
```

A stream and a WebSocket have no total time limit, so a live feed stays open for as long as the server keeps sending. The engine's `maximumRequestDuration` applies to data and upload requests only. A `timeoutIntervalForResource` you set on the engine's configuration does apply to every task, streams and WebSockets included, so leave it at the system default when you open long-lived feeds.

### Open a WebSocket

An `http` or `https` endpoint URL is opened as `ws` or `wss`:

```swift
let socket = try await netti.webSocket(ChatAPI.room(7), pingInterval: .seconds(30))
try await socket.send(ChatMessage(text: "Hi"))
for try await message in socket.messages(as: ChatMessage.self) {
    show(message.text)
}
```

- `send` takes a `String` (text frame), `Data` (binary frame), a ``WebSocketMessage``, or any `Encodable` value, sent as JSON in a text frame with the client's ``JSONManager``.
- ``WebSocketConnection/messages`` yields every incoming ``WebSocketMessage``. ``WebSocketConnection/messages(as:)`` decodes each text or binary frame as JSON, and throws at the first one that does not decode. Iterate from one task only.
- Pings are off by default; `pingInterval` sends one at that interval to keep the connection alive through proxies.
- The incoming sequence ends when the server closes normally and throws ``HTTPRequestError`` on an abnormal close.

Close the connection when you are done. Releasing the connection also closes it:

```swift
let socket = try await netti.webSocket(ChatAPI.room(7))
try await socket.send("bye")
await socket.close(.normalClosure, reason: "done")
```

The handshake is adapted by interceptors but not retried, and a pinning failure throws ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)``. Netti does not reconnect a dropped socket for you. Catch the error from the message loop and open a new connection.

To test WebSocket code without a server, see <doc:Testing>.
