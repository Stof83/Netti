import Foundation
import Testing

@testable import Netti

@Suite("MultipartFormData")
struct MultipartFormDataTests {
    private func temporaryFile(named name: String, contents: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent(name)
        try contents.write(to: fileURL)
        return fileURL
    }

    private func string(_ form: MultipartFormData) throws -> String {
        String(decoding: try form.encode(), as: UTF8.self)
    }

    @Test("given a text field and an image file, when encoded, then both parts have disposition and type")
    func encode_mixedParts() throws {
        let imageURL = try temporaryFile(named: "avatar.png", contents: Data([0x89, 0x50]))
        var form = MultipartFormData(boundary: "B")
        form.append("Ada", name: "name")
        form.append(fileURL: imageURL, name: "avatar")

        let expected = "--B\r\n"
            + "Content-Disposition: form-data; name=\"name\"\r\n\r\n"
            + "Ada\r\n"
            + "--B\r\n"
            + "Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"

        #expect(try form.encode() == Data(expected.utf8) + Data([0x89, 0x50]) + Data("\r\n--B--\r\n".utf8))
        #expect(form.contentType == "multipart/form-data; boundary=B")
    }

    @Test("given two forms, when created, then their boundaries are unique")
    func boundary_isUnique() {
        #expect(MultipartFormData().boundary != MultipartFormData().boundary)
        #expect(MultipartFormData().boundary.hasPrefix("netti.boundary."))
    }

    @Test("given a data part with a file name only, when encoded, then the MIME type is inferred")
    func encode_dataPart_infersMimeType() throws {
        var form = MultipartFormData(boundary: "B")
        form.append(Data("{}".utf8), name: "meta", fileName: "meta.json")

        #expect(try string(form).contains("Content-Type: application/json\r\n"))
    }

    @Test("given quotes and line breaks in names, when encoded, then they are escaped")
    func encode_escapesQuotedValues() throws {
        var form = MultipartFormData(boundary: "B")
        form.append("x", name: "a\"b\r\nc")

        #expect(try string(form).contains("name=\"a%22b%0D%0Ac\""))
    }

    @Test("given a stream part, when encoded twice, then a fresh stream is read each time")
    func encode_streamPart_isRepeatable() throws {
        var form = MultipartFormData(boundary: "B")
        form.append(stream: { InputStream(data: Data("streamed".utf8)) }, length: 8, name: "log", fileName: "log.txt", mimeType: "text/plain")

        let first = try string(form)
        #expect(first.contains("streamed\r\n--B--\r\n"))
        #expect(try string(form) == first)
    }

    @Test("given every part type, when the content length is computed, then it equals the encoded size")
    func contentLength_matchesEncodedSize() throws {
        let fileURL = try temporaryFile(named: "doc.pdf", contents: Data(repeating: 7, count: 300))
        var form = MultipartFormData()
        form.append("value", name: "field")
        form.append(Data(repeating: 1, count: 100), name: "blob")
        form.append(fileURL: fileURL, name: "doc")
        form.append(stream: { InputStream(data: Data(repeating: 2, count: 50)) }, length: 50, name: "stream")

        #expect(try form.contentLength() == UInt64(try form.encode().count))
    }

    @Test("given a missing file, when encoded, then fileSystem is thrown")
    func encode_missingFile_throwsFileSystem() {
        var form = MultipartFormData()
        form.append(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).jpg"), name: "photo")

        #expect {
            try form.encode()
        } throws: { error in
            guard case HTTPRequestError.fileSystem = error else { return false }
            return true
        }
    }

    @Test("given a form below the threshold, when encoded for upload, then it stays in memory")
    func encodedForUpload_belowThreshold_isInMemory() throws {
        var form = MultipartFormData()
        form.append("small", name: "field")

        #expect(try form.encodedForUpload() == .data(try form.encode()))
    }

    @Test("given a form at or above the threshold, when encoded for upload, then it is written to a temporary file")
    func encodedForUpload_aboveThreshold_isOnDisk() throws {
        var form = MultipartFormData()
        form.append(Data(repeating: 9, count: 2048), name: "blob", fileName: "blob.bin")

        guard case .file(let fileURL) = try form.encodedForUpload(memoryThreshold: 1024) else {
            Issue.record("Expected a file-backed form")
            return
        }
        defer { try? FileManager.default.removeItem(at: fileURL) }

        #expect(try Data(contentsOf: fileURL) == form.encode())
    }

    @Test("given an existing destination, when written, then fileSystem is thrown and the file is untouched")
    func writeEncodedData_existingFile_throws() throws {
        let fileURL = try temporaryFile(named: "existing", contents: Data("keep".utf8))
        var form = MultipartFormData()
        form.append("x", name: "field")

        #expect {
            try form.writeEncodedData(to: fileURL)
        } throws: { error in
            guard case HTTPRequestError.fileSystem = error else { return false }
            return true
        }
        #expect(try Data(contentsOf: fileURL) == Data("keep".utf8))
    }

    // MARK: - Injection

    @Test("given a MIME type with CR, LF or NUL, when encoded, then encodingFailed is thrown", arguments: [
        "text/plain\r\nX-Injected: 1", "text/plain\nX", "text/plain\rX", "text/plain\u{0}",
    ])
    func encode_mimeTypeWithControlCharacters_throws(mimeType: String) {
        var form = MultipartFormData(boundary: "B")
        form.append(Data("x".utf8), name: "file", fileName: "a.txt", mimeType: mimeType)

        #expect(isEncodingFailed { () throws(HTTPRequestError) in _ = try form.encode() })
        #expect(isEncodingFailed { () throws(HTTPRequestError) in _ = try form.contentLength() })
    }

    @Test("given a NUL in a part name or file name, when encoded, then encodingFailed is thrown")
    func encode_nulInNames_throws() {
        var named = MultipartFormData(boundary: "B")
        named.append("x", name: "a\u{0}b")
        var filed = MultipartFormData(boundary: "B")
        filed.append(Data("x".utf8), name: "file", fileName: "a\u{0}.txt")

        #expect(isEncodingFailed { () throws(HTTPRequestError) in _ = try named.encode() })
        #expect(isEncodingFailed { () throws(HTTPRequestError) in _ = try filed.encode() })
    }

    @Test("given quotes and line breaks in a file name, when encoded, then they are escaped")
    func encode_escapesFileName() throws {
        var form = MultipartFormData(boundary: "B")
        form.append(Data("x".utf8), name: "file", fileName: "a\"b\r\nc.txt", mimeType: "text/plain")

        #expect(try string(form).contains("filename=\"a%22b%0D%0Ac.txt\""))
    }

    @Test("given a boundary that is not valid under RFC 2046, when encoded, then encodingFailed is thrown", arguments: [
        "", String(repeating: "a", count: 71), "ends-with-space ", "a\r\nb", "semi;colon", "quo\"te", "caf\u{E9}", "a\u{0}b",
    ])
    func encode_invalidBoundary_throws(boundary: String) throws {
        var form = MultipartFormData(boundary: boundary)
        form.append("x", name: "field")
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        #expect(isEncodingFailed { () throws(HTTPRequestError) in _ = try form.encode() })
        #expect(isEncodingFailed { () throws(HTTPRequestError) in try form.writeEncodedData(to: fileURL) })
        #expect(FileManager.default.fileExists(atPath: fileURL.path) == false)
    }

    @Test("given a boundary valid under RFC 2046, when encoded, then it frames the parts", arguments: [
        "B", String(repeating: "a", count: 70), "with space", "'()+_,-./:=?",
    ])
    func encode_validBoundary_encodes(boundary: String) throws {
        var form = MultipartFormData(boundary: boundary)
        form.append("x", name: "field")

        #expect(try string(form).hasPrefix("--\(boundary)\r\n"))
        #expect(try string(form).hasSuffix("--\(boundary)--\r\n"))
    }

    @Test("given a boundary with characters that need quoting, when the content type is read, then the boundary is quoted")
    func contentType_quotesBoundaryWhenNeeded() {
        #expect(MultipartFormData(boundary: "a b").contentType == "multipart/form-data; boundary=\"a b\"")
        #expect(MultipartFormData(boundary: "a:b").contentType == "multipart/form-data; boundary=\"a:b\"")
        #expect(MultipartFormData(boundary: "a.b_c-d").contentType == "multipart/form-data; boundary=a.b_c-d")
    }

    private func isEncodingFailed(_ body: () throws(HTTPRequestError) -> Void) -> Bool {
        do {
            try body()
            return false
        } catch {
            guard case .encodingFailed = error else {
                return false
            }
            return true
        }
    }
}
