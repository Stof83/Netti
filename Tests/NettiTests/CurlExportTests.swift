//
//  CurlExportTests.swift
//  Netti
//

import Foundation
import NettiTesting
import Testing

@testable import Netti

/// `URLRequest.cURLDescription(maskingSensitiveValues:)`: the command reproduces the request,
/// masks credentials by default, and a shell passes every value to `curl` unchanged.
@Suite("cURL export")
struct CurlExportTests {
    private let secret = "secret-token"

    // MARK: - Description

    @Test("given a GET with a header, when described, then it names the method, header and full URL and has no -v")
    func description_get_namesMethodHeaderAndURL() throws {
        let url = try #require(URL(string: "https://api.example.com/users?page=2"))
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let curl = request.cURLDescription()

        #expect(curl.hasPrefix("curl"))
        #expect(curl.contains("-X GET"))
        #expect(curl.contains("'Accept: application/json'"))
        #expect(curl.contains("'https://api.example.com/users?page=2'"))
        #expect(curl.contains("-v") == false)
    }

    #if os(macOS)
    @Test("given a POST with a JSON body, when described, then the command sends exactly that body")
    func description_jsonBody_sentExactly() throws {
        var request = makeURLRequest(method: "POST", headers: ["Content-Type": "application/json"])
        request.httpBody = Data(#"{"name":"Ada"}"#.utf8)

        let arguments = try Self.arguments(passedToCurlBy: request.cURLDescription())

        #expect(Self.value(after: "--data-raw", in: arguments) == #"{"name":"Ada"}"#)
    }
    #endif

    @Test("given a body that is not valid UTF-8, when described, then the command carries no data argument")
    func description_binaryBody_omitted() {
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data([0xFF, 0xFE, 0x00, 0x80])

        let curl = request.cURLDescription()
        let unmasked = request.cURLDescription(maskingSensitiveValues: false)

        for description in [curl, unmasked] {
            #expect(description.contains("--data") == false)
            #expect(description.contains(" -d ") == false)
        }
    }

    @Test("given a request without a URL, when described, then the description is empty")
    func description_noURL_isEmpty() {
        var request = URLRequest(url: TestURL.api)
        request.url = nil

        #expect(request.cURLDescription().isEmpty)
        #expect(request.cURLDescription(maskingSensitiveValues: false).isEmpty)
    }

    // MARK: - Masking

    @Test("given an Authorization header, when described with no arguments, then the name stays and the value is redacted")
    func masking_authorizationHeader_redactedByDefault() {
        let request = makeURLRequest(headers: ["Authorization": "Bearer \(secret)"])

        let curl = request.cURLDescription()

        #expect(curl.contains("Authorization: \(NetworkLogger.redactionMarker)"))
        #expect(curl.contains(secret) == false)
    }

    @Test("given ordinary headers, when described, then their values appear unchanged")
    func masking_ordinaryHeaders_kept() {
        let request = makeURLRequest(headers: ["Accept": "application/json", "X-Request-ID": "r-1"])

        let curl = request.cURLDescription()

        #expect(curl.contains("'Accept: application/json'"))
        #expect(curl.contains("'X-Request-ID: r-1'"))
    }

    @Test("given a credential query item, when described, then its value is not in the URL")
    func masking_credentialQueryItem_redacted() throws {
        let url = try #require(URL(string: "https://api.example.com/items?api_key=abc123&page=2"))

        let curl = URLRequest(url: url).cURLDescription()

        #expect(curl.contains("abc123") == false)
        #expect(curl.contains("api_key=\(NetworkLogger.redactionMarker)"))
        #expect(curl.contains("page=2"))
    }

    @Test("given a POST carrying Authorization and a body, when described, then the body text is absent")
    func masking_credentialRequestBody_omitted() {
        var request = makeURLRequest(method: "POST", headers: ["Authorization": "Bearer \(secret)"])
        request.httpBody = Data(#"{"name":"Ada"}"#.utf8)

        let curl = request.cURLDescription()

        #expect(curl.contains("Ada") == false)
        #expect(curl.contains(secret) == false)
    }

    @Test("given maskingSensitiveValues false, when described, then headers, query values and the body appear as sent")
    func masking_explicitUnmask_showsEverything() throws {
        let url = try #require(URL(string: "https://api.example.com/items?api_key=abc123"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"name":"Ada"}"#.utf8)

        let curl = request.cURLDescription(maskingSensitiveValues: false)

        #expect(curl.contains("'Authorization: Bearer \(secret)'"))
        #expect(curl.contains("api_key=abc123"))
        #expect(curl.contains(#"'{"name":"Ada"}'"#))
        #expect(curl.contains(NetworkLogger.redactionMarker) == false)
    }

    @Test("given a body over the log limit, when described unmasked, then the whole body is kept")
    func masking_unmaskedOversizedBody_kept() throws {
        let body = String(repeating: "a", count: Redaction.maximumLoggedBodySize + 1)
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data(body.utf8)

        #expect(request.cURLDescription(maskingSensitiveValues: false).contains(body))
        #expect(request.cURLDescription().contains(body) == false)
    }

    // MARK: - Logs never unmask

    @Test("given request logging and a credential request, when it is sent, then no log line holds the credential")
    func logger_credentialRequest_neverUnmasked() {
        let messages = Recorder<String>()
        let logger = NetworkLogger { _, message in messages.append(message) }
        var request = makeURLRequest(method: "POST", headers: ["Authorization": "Bearer \(secret)"])
        request.httpBody = Data("password=\(secret)".utf8)

        logger.requestDidSend(request)

        #expect(messages.values.count == 1)
        #expect(messages.values.joined().contains(secret) == false)
        #expect(messages.values.joined().hasPrefix("curl"))
    }

    @Test("given the always-masking wrapper, when it describes a request, then it equals the masked description")
    func asCurl_equalsMaskedDescription() {
        let request = makeURLRequest(headers: ["Authorization": "Bearer \(secret)", "Accept": "application/json"])

        #expect(request.asCurl() == request.cURLDescription(maskingSensitiveValues: true))
    }

    // MARK: - Shell-safe quoting

    #if os(macOS)
    @Test("given $(…) and backtick expressions in a header value, when run in /bin/sh, then curl receives the literal text and nothing runs")
    func shell_metacharactersInHeader_inert() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let value = "$(touch \(sandbox.probe.path)) `touch \(sandbox.probe.path)` ${HOME} ; touch \(sandbox.probe.path)"
        let request = makeURLRequest(headers: ["X-Note": value])

        let arguments = try sandbox.run(request.cURLDescription())

        #expect(arguments.contains("X-Note: \(value)"))
        #expect(FileManager.default.fileExists(atPath: sandbox.probe.path) == false)
    }

    @Test("given a single quote in a body, when run in /bin/sh, then curl receives exactly that body")
    func shell_singleQuoteInBody_preserved() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data("it's".utf8)

        let arguments = try sandbox.run(request.cURLDescription())

        #expect(Self.value(after: "--data-raw", in: arguments) == "it's")
    }

    @Test("given a line feed in a body, when run in /bin/sh, then curl receives that line feed")
    func shell_newlineInBody_preserved() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data("line one\nline two".utf8)

        let arguments = try sandbox.run(request.cURLDescription())

        #expect(Self.value(after: "--data-raw", in: arguments) == "line one\nline two")
    }

    @Test("given terminal control characters in a body, when described, then none is written raw and curl still receives them")
    func shell_controlCharactersInBody_escaped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let body = "a\u{1B}[201~b\rc\u{07}d\ttab\nnext\u{7F}'q'\\"
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data(body.utf8)

        let description = request.cURLDescription()
        let arguments = try sandbox.run(description)

        let raw = description.unicodeScalars.filter { $0.value < 0x20 && $0 != "\n" && $0 != "\t" || $0.value == 0x7F }
        #expect(raw.isEmpty, "raw control characters in \(description.debugDescription)")
        #expect(Self.value(after: "--data-raw", in: arguments) == body)
    }

    @Test("given a control character in a header value, when run in /bin/sh, then curl receives it and nothing runs")
    func shell_controlCharacterInHeader_escaped() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let value = "x\u{1B}[0m $(touch \(sandbox.probe.path))"
        let request = makeURLRequest(headers: ["X-Note": value])

        let description = request.cURLDescription()
        let arguments = try sandbox.run(description)

        #expect(description.unicodeScalars.contains("\u{1B}") == false)
        #expect(arguments.contains("X-Note: \(value)"))
        #expect(FileManager.default.fileExists(atPath: sandbox.probe.path) == false)
    }

    @Test("given a body that starts with @, when run in /bin/sh, then curl receives it as data and not as a file to read")
    func shell_atSignBody_sentAsData() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        var request = makeURLRequest(method: "POST")
        request.httpBody = Data("@/etc/passwd".utf8)

        let arguments = try sandbox.run(request.cURLDescription())

        #expect(Self.value(after: "--data-raw", in: arguments) == "@/etc/passwd")
        #expect(arguments.contains("-d") == false)
    }

    @Test("given shell metacharacters in the method and the URL, when run in /bin/sh, then nothing runs")
    func shell_metacharactersInMethodAndURL_inert() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let url = try #require(URL(string: "https://api.example.com/a?q='%24(touch%20\(sandbox.probe.lastPathComponent))'"))
        var request = URLRequest(url: url)
        request.httpMethod = "GET; touch \(sandbox.probe.path)"

        let arguments = try sandbox.run(request.cURLDescription(maskingSensitiveValues: false))

        #expect(arguments.contains("GET; touch \(sandbox.probe.path)"))
        #expect(arguments.contains(url.absoluteString))
        #expect(FileManager.default.fileExists(atPath: sandbox.probe.path) == false)
    }

    @Test("given header values with quotes, backslashes and double quotes, when run in /bin/sh, then curl receives them unchanged")
    func shell_quotesAndBackslashes_preserved() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let value = #"a'b"c\d'"#
        let request = makeURLRequest(headers: ["X-Note": value])

        let arguments = try sandbox.run(request.cURLDescription())

        #expect(arguments.contains("X-Note: \(value)"))
    }
    #endif

    // MARK: - Helpers

    /// The arguments `curl` receives when `/bin/sh` runs `description`, on macOS only.
    private static func arguments(passedToCurlBy description: String) throws -> [String] {
        #if os(macOS)
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        return try sandbox.run(description)
        #else
        return []
        #endif
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

#if os(macOS)
/// A temporary directory holding a stub `curl` that prints each of its arguments followed by a NUL
/// byte, and a path no test command may create.
private struct Sandbox {
    let directory: URL
    let probe: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("netti-curl-\(UUID().uuidString)")
        probe = directory.appendingPathComponent("netti-probe")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("curl")
        try "#!/bin/sh\nprintf '%s\\0' \"$@\"\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
    }

    /// Runs `description` in `/bin/sh` with the stub first on `PATH`; returns the stub's arguments.
    func run(_ description: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", description]
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "\(directory.path):/usr/bin:/bin", "HOME": "/nonexistent"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var parts = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        if parts.last == "" {
            parts.removeLast()
        }
        return parts
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
#endif
