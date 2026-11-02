# Multiple Requests & Queues

Run requests concurrently or in sequence, queue them with priorities and an offline hold, and let identical requests share one transfer.

## Overview

| Need | Use |
|---|---|
| A few requests of different types at once | `async let` |
| The same request for many inputs, fail fast | ``Netti/concurrent(_:maxConcurrency:_:)`` |
| The same request for many inputs, keep every outcome | ``Netti/concurrentSettled(_:maxConcurrency:_:)`` |
| One request after another | ``Netti/sequential(_:_:)`` |
| Ordering, priorities, pause, or holding work while offline | ``RequestQueue`` |

Identical in-flight `GET` and `HEAD` requests are deduplicated automatically.

### Different requests at once

Use the language. No extra API is needed:

```swift
async let user: HTTPResponse<User> = netti.get(UserAPI.me)
async let rides: HTTPResponse<[Ride]> = netti.get(RideAPI.history)
let (me, history) = try await (user, rides)
show(me.data)
show(history.data)
```

### Many inputs, concurrently

``Netti/concurrent(_:maxConcurrency:_:)`` runs the operation for every element, at most `maxConcurrency` at a time (6 by default), and returns the results in input order:

```swift
let users: [User?] = try await netti.concurrent(ids, maxConcurrency: 4) { id in
    try await netti.get(UserAPI.user(id)).data
}
```

Annotate the result type. Inside the closure nothing else names it, so without the annotation the `Empty` overload of `get` is chosen and you get `[Empty?]`.

The first failure cancels the operations still running and is thrown once they stop. Cancelling the calling task cancels every operation. The error type is the closure's own: `any Error` for a plain closure, ``HTTPRequestError`` when the closure is annotated `throws(HTTPRequestError)`.

### Many inputs, every outcome

``Netti/concurrentSettled(_:maxConcurrency:_:)`` never stops early. It returns a `Result` per element, in input order:

```swift
let outcomes = await netti.concurrentSettled(photoURLs) { url in
    try await netti.upload(PhotoAPI.upload, fileURL: url)
}
let failedURLs = zip(photoURLs, outcomes).compactMap { url, outcome in
    if case .failure = outcome { url } else { nil }
}
```

### One after another

``Netti/sequential(_:_:)`` runs the operation for each element in order, and stops at the first failure:

```swift
let results: [HTTPResponse<Empty>] = try await netti.sequential(migrations) { step in
    try await netti.post(MigrationAPI.run, body: step)
}
```

### Queue requests

A ``RequestQueue`` runs operations in order, a limited number at a time. Higher priorities start first, and operations of equal priority start in the order they were enqueued. Each caller awaits its own operation's result:

```swift
let queue = netti.queue(.concurrent(max: 2))
let receipt: HTTPResponse<Receipt> = try await queue.enqueue(priority: .high) {
    try await netti.post(PaymentAPI.pay, body: payment)
}
```

| Mode | Behavior |
|---|---|
| ``RequestQueue/Mode/serial`` | One operation at a time; the default |
| ``RequestQueue/Mode/serial(waitsForConnectivity:)`` | One at a time, optionally held while offline |
| ``RequestQueue/Mode/concurrent(max:waitsForConnectivity:)`` | Up to `max` at a time, optionally held while offline |

A queue that waits for connectivity holds its pending operations while the device is offline and starts them on reconnect. Operations already running are not interrupted. ``Netti/queue(_:)`` creates a queue that uses the client's ``Netti/connectivity``; ``RequestQueue/init(_:connectivity:)`` takes any source. The result of `enqueue` is discardable, so a fire-and-forget write needs no `_ =`:

```swift
let outbox = netti.queue(.serial(waitsForConnectivity: true))
try await outbox.enqueue { try await netti.post(TripAPI.log, body: entry) }
```

Control the queue from any task:

```swift
let queue = netti.queue(.concurrent(max: 2))
await queue.pause()
let waiting = await queue.pendingCount
let running = await queue.runningCount
await queue.resume()
await queue.cancelAll()
```

``RequestQueue/pause()`` stops new operations from starting; running ones finish. ``RequestQueue/cancelAll()`` cancels pending and running operations, and their callers receive ``HTTPRequestError/cancelled``. Cancelling a caller's task withdraws its pending operation, or cancels it if it is running. `enqueue` throws untyped errors: the operation's own error, or ``HTTPRequestError/cancelled``.

The queue lives in memory. Pending work is lost when the app terminates.

### In-flight deduplication

When identical `GET` or `HEAD` requests overlap, the client sends one and every caller receives its response. Identical means the same method, URL, body and headers, compared after interceptors ran, so requests carrying different tokens are never merged. Each caller decodes the shared response into its own type.

A caller that is cancelled stops waiting at once. The transfer itself is cancelled only when every caller has left. Deduplication is on by default. Turn it off per client:

```swift
let netti = Netti(deduplicatesRequests: false)
```

Deduplication covers requests in flight at the same moment. It does not cache. For reuse across time, see <doc:CachingAndOffline>.

### Limit connections per host

``URLSessionNetworkService`` passes `maxConnectionsPerHost` to its session's `httpMaximumConnectionsPerHost`. That caps how many connections the engine opens to one host, whatever the batch or queue settings:

```swift
let netti = Netti(service: URLSessionNetworkService(maxConnectionsPerHost: 4))
```
