# ``Netti``

Async/await networking for Apple platforms: one method per HTTP verb, typed errors, and every advanced feature opt-in through a property on the client.

## Overview

Describe each endpoint once as an ``HTTPRequest`` value, then call the verb you need on a ``Netti`` client. The common case is one line with no configuration:

```swift
let netti = Netti()
let user: User? = try await netti.get(UserAPI.user(42)).data
try await netti.delete(UserAPI.user(42))
```

Every request runs through one pipeline: encode, adapt, send, validate, retry, cache, decode. Interceptors, retry, validation and monitoring therefore behave the same for plain requests, uploads, downloads and streams. Every API throws ``HTTPRequestError`` with typed throws, and a non-2xx response is returned with its status code rather than thrown unless you turn validation on.

The default engine, ``URLSessionNetworkService``, is built on `URLSession` alone. It is secure by default: TLS 1.2 or later, redirects through ``RedirectHandler/secure``, which never downgrades to `http` or sends credentials to another origin, and a 64 MB response cap. Certificate pinning, the redirect policy, the response cap and the connection limit per host are configured on it. See <doc:Security>.

Test support ships as a separate product, `NettiTesting`, with a stub server that keeps your tests off the network. See <doc:Testing>.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:MakingRequests>
- ``Netti``
- ``HTTPRequest``
- ``HTTPMethod``
- ``HTTPHeaders``
- ``HTTPHeader``
- ``JSONManager``
- ``KeyEncodingDecodingStrategy``
- ``NetworkService``
- ``URLSessionNetworkService``

### Requests and responses

- ``HTTPResponse``
- ``HTTPDownloadResponse``
- ``HTTPStreamResponse``
- ``Empty``
- ``EmptyResponse``
- ``ParameterDestination``
- ``RedirectHandler``

### Encoding

- ``URLEncodedFormEncoder``
- ``URLEncodedFormParameterEncoder``
- ``JSONParameterEncoder``
- ``MultipartFormData``

### Transfers

- <doc:UploadAndDownload>
- ``UploadMethod``
- ``UploadSource``
- ``DownloadOptions``
- ``TransferProgress``
- ``ProgressHandler``

### Streaming

- <doc:StreamingAndWebSocket>
- ``AsyncLineSequence``
- ``ServerSentEvent``
- ``ServerSentEventSequence``
- ``WebSocketConnection``
- ``WebSocketMessage``
- ``WebSocketTransport``

### Security

- <doc:Security>
- <doc:CertificatePinning>
- ``ServerTrustPolicy``
- ``ServerTrustEvaluator``
- ``ServerTrustEvaluating``
- ``PinnedCertificateExpiry``
- ``IdempotencyKeyAdapter``

### Interception and retry

- <doc:InterceptorsAndRetry>
- ``RequestInterceptor``
- ``RequestAdapter``
- ``RequestRetrier``
- ``CompositeInterceptor``
- ``AuthenticationInterceptor``
- ``AuthToken``
- ``RetryPolicy``
- ``RetryDecision``
- ``RetryContext``

### Validation

- <doc:ValidationAndErrors>
- ``ResponseValidation``
- ``HTTPRequestError``

### Caching

- <doc:CachingAndOffline>
- ``HTTPCachePolicy``

### Orchestration

- <doc:MultipleRequestsAndQueues>
- ``RequestQueue``

### Monitoring

- <doc:Observability>
- ``EventMonitor``
- ``CompositeEventMonitor``
- ``NetworkLogger``
- ``NetworkMonitor``
- ``ConnectivitySource``

### Test support

- <doc:Testing>

### Adopting Netti 2.0

- <doc:MigratingFrom1x>
- <doc:NettiVsAlamofire>

### Deprecated

- ``ParameterEncoder``
- ``URLSessionConfigurationWrapper``
- ``JSONBodyParameterEncoder``
- ``URLQueryParameterEncoder``
