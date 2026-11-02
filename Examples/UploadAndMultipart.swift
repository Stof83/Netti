//
//  UploadAndMultipart.swift
//  Netti
//

import Foundation
import NettiTesting

/// Uploading in-memory data, a file and a multipart form, with progress.
///
/// Runs offline: a `StubServer` answers every upload and records the body.
func uploadAndMultipartExample() async throws {
    struct Receipt: Codable, Sendable {
        let id: Int
    }

    let server = StubServer()
    server.stub(.post, "https://api.example.com/v1/users", json: Receipt(id: 1))
    server.stub(.put, "https://api.example.com/v1/users", json: Receipt(id: 2))
    let netti = server.netti()

    // MARK: - Data

    let payload = Data("hello".utf8)
    let fromData: Receipt? = try await netti.upload(UserAPI.users, data: payload).data
    report("data      -> receipt \(fromData?.id ?? 0)")

    // MARK: - File

    let file = FileManager.default.temporaryDirectory.appendingPathComponent("netti-example-\(UUID().uuidString).txt")
    try Data("file contents".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }

    // Progress arrives on a background queue; hop to the main actor before touching UI.
    let completed = Counter()
    let fromFile: Receipt? = try await netti.upload(UserAPI.users, fileURL: file, method: .put) { progress in
        if progress.fractionCompleted >= 1 {
            completed.increment()
        }
    }.data
    report("file      -> receipt \(fromFile?.id ?? 0), progress reached 100%: \(completed.value > 0)")
    try expect(completed.value > 0, "progress never reached 1.0")

    // MARK: - Multipart

    var form = MultipartFormData()
    form.append("Ada", name: "name")
    form.append(payload, name: "note", fileName: "note.txt")
    form.append(fileURL: file, name: "attachment")
    let fromForm: Receipt? = try await netti.upload(UserAPI.users, multipart: form).data

    let sent = try expectValue(server.requests.last, "no upload recorded")
    let contentType = sent.headers["Content-Type"] ?? ""
    report("multipart -> receipt \(fromForm?.id ?? 0), \(sent.body?.count ?? 0) bytes sent")
    try expect(contentType.hasPrefix("multipart/form-data; boundary="), "missing multipart Content-Type")
}
