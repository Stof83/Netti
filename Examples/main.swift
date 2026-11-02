//
//  main.swift
//  Netti
//

import Foundation

// Runs every example in order, reports failures, and exits non-zero if any example throws.
//
// Not run here, because they need a real TLS handshake: `pinnedRequestExample(netti:)`.
// They still compile, so `swift build` keeps them from going stale.

let examples: [(name: String, run: () async throws -> Void)] = [
    ("RequestsAndVerbs", requestsAndVerbsExample),
    ("Configuration", configurationExample),
    ("UploadAndMultipart", uploadAndMultipartExample),
    ("DownloadAndResume", downloadAndResumeExample),
    ("Authentication", authenticationExample),
    ("InterceptorsAndRetry", interceptorsAndRetryExample),
    ("ValidationAndErrors", validationAndErrorsExample),
    ("CachingAndOffline", cachingAndOfflineExample),
    ("StreamingAndSSE", streamingAndSSEExample),
    ("WebSocket", webSocketExample),
    ("QueuesBatchDedup", queuesBatchDedupExample),
    ("Observability", observabilityExample),
    ("Redirects", redirectsExample),
    ("CertificatePinning", certificatePinningExample),
    ("Testing", testingExample),
]

var failures: [String] = []

for example in examples {
    report("== \(example.name)")
    do {
        try await example.run()
    } catch {
        failures.append(example.name)
        report("FAILED \(example.name): \(error)")
    }
}

if failures.isEmpty {
    report("\nAll \(examples.count) examples passed.")
} else {
    report("\n\(failures.count) of \(examples.count) examples failed: \(failures.joined(separator: ", "))")
    exit(1)
}
