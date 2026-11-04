# Upload & Download

Upload data, files and multipart forms, and download to disk with progress and resume.

## Overview

Uploads and downloads go through the same pipeline as every other request: interceptors, retry, validation and monitoring apply. Progress is optional on every call.

### Upload data or a file

```swift
let receipt: Receipt? = try await netti.upload(ReceiptAPI.scan, data: jpegData).data
let stored: Receipt? = try await netti.upload(ReceiptAPI.scan, fileURL: photoURL, method: .put).data
```

Uploads use `POST` unless you pass another ``UploadMethod`` (`.put` or `.patch`). A file is read from disk as it is sent. A file that cannot be read fails with ``HTTPRequestError/fileSystem(_:)`` before any network traffic. As with the verbs, omit the type annotation to ignore the response body.

### Upload a multipart form

Build a ``MultipartFormData`` from text fields, in-memory data, files and streams:

```swift
var form = MultipartFormData()
form.append("Ada", name: "name")
form.append(fileURL: avatarURL, name: "avatar")
let profile: Profile? = try await netti.upload(ProfileAPI.update, multipart: form).data
```

The boundary goes into the `Content-Type` header. A form of 10 MB or more (``MultipartFormData/encodingMemoryThreshold``) is written to a temporary file and streamed from it; the file is deleted when the call returns. The MIME type of a file part is inferred from its extension unless you pass `mimeType:`.

### Track progress

The progress handler receives a ``TransferProgress``. It is called on a background queue, with increasing values, and at least once with a ``TransferProgress/fractionCompleted`` of `1.0` on success. Hop to the main actor before touching UI:

```swift
@MainActor final class UploadModel {
    var fraction = 0.0

    func upload(_ data: Data) async throws {
        try await netti.upload(PhotoAPI.upload, data: data) { progress in
            Task { @MainActor in self.fraction = progress.fractionCompleted }
        }
    }
}
```

``TransferProgress/totalUnitCount`` is `nil` when the size is unknown, for example a download without `Content-Length`.

### Track the progress of a large response

`get`, `post`, `put`, `patch` and `delete` accept the same `progress:` handler, so a large REST response can show how much of it has arrived:

```swift
let catalog: Catalog? = try await netti.get(CatalogAPI.full, progress: { progress in
    Task { @MainActor in self.fraction = progress.fractionCompleted }
}).data
```

The handler follows the contract above, with these details for data requests:

- It is called at most once per 16 KiB and once per 1% of the announced length, whichever is larger, so a server sending tiny chunks cannot flood it. A body smaller than 16 KiB calls it once, with `1.0`.
- ``TransferProgress/totalUnitCount`` is `nil` when the response has no `Content-Length`, or one that is zero, negative or smaller than the bytes that actually arrive. The completed count is always the bytes received.
- A failed request never reports `1.0`. A response served from the offline cache or from sample data does not call the handler.
- A request with a handler does not share its transfer with an identical in-flight `GET` or `HEAD` (see <doc:MultipleRequestsAndQueues>), so the handler sees the bytes of its own request. Adding a handler to a request that would have been shared costs one extra transfer.
- When a retry follows a partial body, the completed count never decreases: progress stays still until the new attempt passes the previous one, and `1.0` is reported once, for the attempt that succeeds.
- A custom ``NetworkService`` that does not implement ``NetworkService/data(for:progress:)`` still works: the handler is called once, with `1.0`, after the response arrives.

### Download a file

``Netti/download(_:to:options:resumeData:progress:)`` sends a `GET` and saves the body to disk:

```swift
let file = try await netti.download(VideoAPI.movie, to: movieURL).fileURL
```

Missing parent directories are created by default. Pass `options: [.createIntermediateDirectories, .removePreviousFile]` to replace a file that is already at the destination; without ``DownloadOptions/removePreviousFile`` an existing file makes the move fail with ``HTTPRequestError/fileSystem(_:)``. Without a destination the file stays in a temporary directory, so move it before the app relaunches.

### Resume a failed download

When a download fails or is cancelled after part of the body arrived, the error is ``HTTPRequestError/downloadFailed(_:resumeData:)``. Its ``HTTPRequestError/resumeData`` continues the transfer, if the server supports it:

```swift
var resumeData: Data?
do {
    let file = try await netti.download(VideoAPI.movie, to: movieURL).fileURL
    show(file)
} catch {
    resumeData = error.resumeData
}

if let resumeData {
    let file = try await netti.download(VideoAPI.movie, to: movieURL, resumeData: resumeData).fileURL
    show(file)
}
```

Cancelling the task that awaits a download cancels the transfer. When the server supports resuming, that error carries resume data too. Without resume data, the error is the failure itself, such as ``HTTPRequestError/cancelled``.

### Run uploads in parallel

To upload many files, use a batch. Each upload still reports its own progress, and you get every outcome:

```swift
let outcomes = await netti.concurrentSettled(photoURLs, maxConcurrency: 3) { url in
    try await netti.upload(PhotoAPI.upload, fileURL: url)
}
```

See <doc:MultipleRequestsAndQueues> for batches and queues.
