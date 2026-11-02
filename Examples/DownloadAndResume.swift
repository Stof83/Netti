//
//  DownloadAndResume.swift
//  Netti
//

import Foundation
import NettiTesting

/// Downloading to a file, then resuming a download that failed halfway.
///
/// Runs offline: a `StubNetworkService` plays a server whose first download drops after part of
/// the body and whose second one continues from the resume data (downloads need the stub service,
/// since `StubServer` only answers data requests).
func downloadAndResumeExample() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-example-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = directory.appendingPathComponent("movie.bin")
    let partial = Data("first-half".utf8)

    let service = StubNetworkService(download: { request, resumeData, progress in
        let response = request.url.flatMap { HTTPURLResponse(url: $0, statusCode: 200, httpVersion: nil, headerFields: nil) }
        guard resumeData != nil else {
            // The connection drops: URLSession hands back what it has as resume data.
            return HTTPDownloadResponse(request: request, response: response, fileURL: nil, resumeData: partial, error: URLError(.networkConnectionLost))
        }
        progress?(TransferProgress(completedUnitCount: 20, totalUnitCount: 20))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? Data("first-half-second-half".utf8).write(to: file)
        return HTTPDownloadResponse(request: request, response: response, fileURL: file)
    })
    let netti = Netti(service: service)
    netti.isLoggingEnabled = false

    // MARK: - First attempt fails with resume data

    var resumeData: Data?
    do {
        let finished = try await netti.download(UserAPI.users, to: destination)
        report("download -> finished at once: \(finished.fileURL?.lastPathComponent ?? "nil")")
    } catch {
        resumeData = error.resumeData
        report("download -> failed, kept \(resumeData?.count ?? 0) bytes of resume data")
    }
    let kept = try expectValue(resumeData, "the failed download carried no resume data")

    // MARK: - Resume

    let file = try await netti.download(UserAPI.users, to: destination, resumeData: kept).fileURL
    let saved = try expectValue(file, "no file URL")
    let contents = String(decoding: (try? Data(contentsOf: saved)) ?? Data(), as: UTF8.self)
    report("resume   -> saved \(saved.lastPathComponent): \(contents)")
    try expect(contents == "first-half-second-half", "unexpected file contents: \(contents)")
    try expect(service.downloads.last?.resumeData == kept, "the second attempt did not receive the resume data")
}
