# Observability

Log every request, observe the request lifecycle with event monitors, and read transfer metrics.

## Overview

In DEBUG builds, each client logs through a ``NetworkLogger``; in release builds, logging is off. Add your own ``EventMonitor`` types for analytics, tracing or performance tracking. They see every request, whatever its kind.

### The built-in logger

``NetworkLogger`` writes to the unified system log, subsystem `Netti`, category `networking`:

- every request as it is sent, as a cURL command you can paste into a terminal;
- every response, with its method, URL, status code and pretty-printed JSON body;
- every failure, and a readable description of each decoding error with its coding path, and with the body when it is JSON. A body that is not JSON shows only its byte count.

Every message is marked private, so Console shows its content only while a debugger is attached. Xcode's console, SwiftUI previews included, shows the unified log, so the logger never prints.

Logging is on by default in DEBUG builds and off in release builds, so request details never reach a shipped app's log unless you ask for them. Change it per client:

```swift
netti.isLoggingEnabled = false
```

### What the logger redacts

A name marks a credential when, compared case-insensitively:

- it contains `auth`, `token`, `key`, `secret`, `session`, `cookie`, `password`, `passwd`, `pwd`, `signature`, `credential` or `otp`, as in `X-Amz-Signature` or `totp`;
- one of its words is `sig` or `pin`, splitting at every character that is not a letter or digit and at every lowercase-to-uppercase change: `X-Sig` and `userPin` match, `design` and `spinner` do not;
- it is `code`, the OAuth authorization code, or `X-Code`; `countryCode` does not match.

The logger then:

- replaces the value of every such header and query item, and any password in the URL, with ``NetworkLogger/redactionMarker`` (`<redacted>`);
- replaces the whole body of a request that carries such a header;
- in any other body, request or response, redacts the value of every such key at any depth when the body is JSON, and per pair when it is form-urlencoded. A request body in another format is logged as it is; a response body that is not JSON is not logged.
- never parses or logs a body over 64 KB, request or response; only its byte count is logged.

``HTTPHeaders`` and ``HTTPHeader`` descriptions apply the same rules. ``HTTPRequestError``'s description shows only the case, status, method, host and path, so it is safe to send to a crash reporter.

The rules over-redact on purpose: `Idempotency-Key`, `author`, `footprint`, and a JSON `"code"` field such as an error code are hidden too.

Your own monitors are not redacted: they receive each request as it is sent, credentials included. Redact before you forward anything to analytics.

### Copy a request as cURL

`URLRequest.cURLDescription(maskingSensitiveValues:)` renders any `URLRequest` as a `curl` command. An event monitor sees each request as it is sent, interceptor headers included, so it is the place to capture one:

```swift
struct CurlMonitor: EventMonitor {
    func requestDidSend(_ request: URLRequest) {
        let command = request.cURLDescription()   // credentials replaced by <redacted>
        // hand `command` to your own tooling
        _ = command
    }
}
```

The command reproduces the method, URL, headers and UTF-8 text body, and adds no flag such as `-v`. A body that is not valid UTF-8 is left out, and a request without a URL gives an empty string.

By default the description applies the same redaction rules as the logger. Pass `false` to get every value as sent, for a command you run yourself:

```swift
let asSent = request.cURLDescription(maskingSensitiveValues: false)
```

Treat an unmasked command like a password: it holds live tokens. The built-in logger always masks, whatever you do elsewhere.

Every header, body and URL is single-quoted with embedded single quotes escaped, so a shell hands each value to `curl` unchanged and runs nothing else. A body is sent with `--data-raw`, so one that starts with `@` is sent as text and never read from a file.

### Write an event monitor

Every ``EventMonitor`` method has a no-op default, so implement only the events you need. Events arrive in order, synchronously, on the task that runs the request. Keep them cheap, and hand heavy work to another task.

| Event | When |
|---|---|
| ``EventMonitor/requestDidCreate(_:)`` | The request was built, before adaptation |
| ``EventMonitor/requestDidAdapt(_:to:)`` | Interceptors changed the request |
| ``EventMonitor/requestDidSend(_:)`` | An attempt was handed to the engine |
| ``EventMonitor/requestWillRetry(_:retryCount:delay:)`` | A failed attempt will be sent again after `delay` |
| ``EventMonitor/requestDidReceiveResponse(_:)`` | A response arrived, whatever its status |
| ``EventMonitor/requestDidCollectMetrics(_:for:)`` | The engine collected `URLSessionTaskMetrics` |
| ``EventMonitor/requestDidFail(_:error:)`` | The request failed for good |

```swift
import os

struct SlowRequestMonitor: EventMonitor {
    let logger = Logger(subsystem: "com.example.app", category: "performance")

    func requestDidCollectMetrics(_ metrics: URLSessionTaskMetrics, for request: URLRequest) {
        let seconds = metrics.taskInterval.duration
        if seconds > 2 {
            logger.warning("Slow request \(request.url?.path ?? "", privacy: .public): \(seconds)s")
        }
    }

    func requestWillRetry(_ request: URLRequest, retryCount: Int, delay: Duration) {
        logger.info("Retry \(retryCount) of \(request.url?.path ?? "", privacy: .public) in \(delay)")
    }
}

let netti = Netti()
netti.monitors = [SlowRequestMonitor()]
```

Monitors must be `Sendable`. Your monitors run after the built-in logger, in the order of ``Netti/monitors``. ``CompositeEventMonitor`` combines several monitors into one when you need to pass them around as a unit.

### Read metrics on a response

Metrics are also attached to each response, when the engine collects them:

```swift
let response: HTTPResponse<User> = try await netti.get(UserAPI.me)
if let metrics = response.metrics {
    report(metrics.transactionMetrics.last?.networkProtocolName)
}
```

``HTTPDownloadResponse`` carries ``HTTPDownloadResponse/metrics`` the same way.

### Watch connectivity

``NetworkMonitor/shared`` reports whether a network path is available. It drives the offline cache and queues that wait for connectivity, and SwiftUI can observe it. See <doc:CachingAndOffline>.
