# Validation & Errors

Decide which responses count as failures, and handle every error Netti throws.

## Overview

By default Netti *returns* every response it receives, whatever the status, with the body decoded when it can be. Code that reads `statusCode == 401` itself keeps working. Validation is opt-in: once it is on, an unacceptable response throws.

### Turn validation on

``ResponseValidation`` with its defaults accepts `2xx` statuses only, and a `Content-Type` that matches the request's `Accept` header. A request without `Accept`, or a response with an empty body, skips the content-type check.

```swift
let netti = Netti()
netti.validation = ResponseValidation()
```

Each rule can be changed. ``ResponseValidation/custom`` runs last, and whatever it throws becomes the reason of ``HTTPRequestError/validationFailed(_:response:)``:

```swift
struct MissingRequestID: Error {}

let validation = ResponseValidation(
    statusCodes: Set(200..<300).union([304]),
    contentTypes: .only(["application/json", "text/*"]),
    custom: { response in
        if response.response?.value(forHTTPHeaderField: "X-Request-ID") == nil {
            throw MissingRequestID()
        }
    }
)
```

### Override validation per endpoint

An endpoint's ``HTTPRequest/validation`` replaces the client's rules. ``ResponseValidation/disabled`` accepts every response, even when the client validates:

```swift
enum HealthAPI: HTTPRequest {
    case status

    var baseURL: URL? { URL(string: "https://api.example.com") }
    var basePath: String { "" }
    var path: String { "health" }
    var headers: HTTPHeaders { [] }
    var validation: ResponseValidation? { .disabled }
}
```

### Handle errors

Every API throws ``HTTPRequestError`` with typed throws, so `catch` clauses match its cases without casting:

```swift
struct APIError: Decodable {
    let message: String
}

let strict = Netti()
strict.validation = ResponseValidation()
do {
    let user: User? = try await strict.get(UserAPI.me).data
    show(user)
} catch .unacceptableStatusCode(404, _) {
    showSignUp()
} catch .unacceptableStatusCode(_, let response) {
    let apiError = try? JSONDecoder().decode(APIError.self, from: response.rawData ?? Data())
    report(apiError?.message)
} catch {
    report(error.response?.statusCode)
}
```

``HTTPRequestError/response`` returns the raw response whenever one was received, including inside ``HTTPRequestError/retryLimitExceeded(attempts:lastError:)``.

| Case | Thrown when |
|---|---|
| ``HTTPRequestError/invalidURL`` | The endpoint's URL cannot be built, for example a `nil` base URL |
| ``HTTPRequestError/encodingFailed(_:)`` | The query, body or a multipart stream cannot be encoded |
| ``HTTPRequestError/requestFailed(_:)`` | The transport failed before a response, with the `URLError` |
| ``HTTPRequestError/serverTrustEvaluationFailed(host:reason:)`` | The server trust policy rejected the host; see <doc:CertificatePinning> |
| ``HTTPRequestError/unacceptableStatusCode(_:response:)`` | Validation rejected the status, or retries ran out on a status |
| ``HTTPRequestError/unacceptableContentType(_:response:)`` | Validation rejected the `Content-Type`; `nil` when the header is missing |
| ``HTTPRequestError/validationFailed(_:response:)`` | Your custom validation threw |
| ``HTTPRequestError/decodingFailed(_:response:)`` | A `2xx` body did not decode as the requested type |
| ``HTTPRequestError/cancelled`` | The calling task, or a queue, cancelled the request |
| ``HTTPRequestError/retryLimitExceeded(attempts:lastError:)`` | Every allowed retry was used; see <doc:InterceptorsAndRetry> |
| ``HTTPRequestError/fileSystem(_:)`` | A file could not be read, written or moved |
| ``HTTPRequestError/downloadFailed(_:resumeData:)`` | A download failed after part of the body arrived; see <doc:UploadAndDownload> |

### Decoding failures

A `2xx` body that does not decode throws ``HTTPRequestError/decodingFailed(_:response:)``. The client logs the `DecodingError` with the coding path and the raw body, unless logging is off. A non-2xx body that does not decode is not an error: the response is returned with `data == nil` and ``HTTPResponse/rawData`` intact, so you can still read the status and the server's error payload.

Use ``Empty`` as the response type, or call a verb without naming a type, when the body does not matter. It always decodes.

### Cancellation

Cancelling the task that awaits a request cancels the transfer and throws ``HTTPRequestError/cancelled``. That includes a request waiting out a retry delay.
