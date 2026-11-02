import Foundation
import Testing

@testable import Netti

@Suite("HTTPHeaders content type")
struct HTTPHeadersTests {
    @Test("given headers, when contentType is set and read, then it is case-insensitive and nil removes it")
    func contentType_getSetRemove() {
        var headers: HTTPHeaders = ["content-type": "text/plain"]
        #expect(headers.contentType == "text/plain")

        headers.contentType = "application/json"
        #expect(headers.contentType == "application/json")
        #expect(headers.count == 1)

        headers.contentType = nil
        #expect(headers.contentType == nil)
    }

    @Test("given the content type helpers, when read, then values match the encoders")
    func contentTypeHelpers() {
        #expect(HTTPHeader.jsonContentType == HTTPHeader(name: "Content-Type", value: "application/json"))
        #expect(HTTPHeader.formURLEncodedContentType.value == "application/x-www-form-urlencoded; charset=utf-8")
        #expect(HTTPHeader.multipartFormDataContentType(boundary: "B").value == "multipart/form-data; boundary=B")
    }

    @Test("given a JSON manager, when decoding Empty from an empty body, then it succeeds")
    func jsonManager_emptyResponse() throws {
        #expect(throws: Never.self) {
            try JSONManager().decode(Empty.self, from: nil)
        }
    }
}

@Suite("HTTPHeaders collection")
struct HTTPHeadersCollectionTests {
    @Test("given duplicate names in any case, when built from a list, then the last value wins")
    func init_fromList_collapsesCaseInsensitiveDuplicates() {
        let headers = HTTPHeaders([HTTPHeader(name: "Accept", value: "a"), HTTPHeader(name: "ACCEPT", value: "b")])

        #expect(headers.count == 1)
        #expect(headers["accept"] == "b")
    }

    @Test("given a header, when added by name or value, then it updates in place rather than duplicating")
    func add_updatesExistingHeader() {
        var headers = HTTPHeaders()
        headers.add(name: "X-A", value: "1")
        headers.add(HTTPHeader(name: "x-a", value: "2"))
        headers.add(name: "X-B", value: "3")

        #expect(headers.count == 2)
        #expect(headers["X-A"] == "2")
    }

    @Test("given a subscript, when set to a value or nil, then it adds, replaces and removes")
    func subscript_setsAndRemoves() {
        var headers = HTTPHeaders()
        headers["X-A"] = "1"
        headers["x-a"] = "2"
        #expect(headers.value(for: "X-A") == "2")

        headers["X-A"] = nil
        #expect(headers.isEmpty)
    }

    @Test("given unsorted headers, when sorted, then names are ordered case-insensitively and sorted() leaves the original alone")
    func sort_ordersByLowercasedName() {
        let original: HTTPHeaders = [HTTPHeader(name: "b", value: "1"), HTTPHeader(name: "A", value: "2"), HTTPHeader(name: "c", value: "3")]

        let sorted = original.sorted()
        var inPlace = original
        inPlace.sort()

        #expect(sorted.map(\.name) == ["A", "b", "c"])
        #expect(inPlace.map(\.name) == ["A", "b", "c"])
        #expect(original.map(\.name) == ["b", "A", "c"])
    }

    @Test("given headers, when iterated, indexed and printed, then they behave as an ordered collection")
    func collection_conformances() {
        let headers: HTTPHeaders = [HTTPHeader(name: "A", value: "1"), HTTPHeader(name: "B", value: "2")]

        #expect(headers[0] == HTTPHeader(name: "A", value: "1"))
        #expect(headers.map(\.value) == ["1", "2"])
        #expect(headers.description == "A: 1\nB: 2")
    }

    @Test("given the header factories, when built, then each uses its standard name")
    func factories_useStandardNames() {
        #expect(HTTPHeader.accept("x") == HTTPHeader(name: "Accept", value: "x"))
        #expect(HTTPHeader.acceptCharset("x") == HTTPHeader(name: "Accept-Charset", value: "x"))
        #expect(HTTPHeader.acceptLanguage("x") == HTTPHeader(name: "Accept-Language", value: "x"))
        #expect(HTTPHeader.acceptEncoding("x") == HTTPHeader(name: "Accept-Encoding", value: "x"))
        #expect(HTTPHeader.contentEncoding("x") == HTTPHeader(name: "Content-Encoding", value: "x"))
    }

    @Test("given a username and password, when building basic authorization, then the credential is base64 encoded")
    func authorization_basic() {
        let header = HTTPHeader.authorization(username: "aladdin", password: "open sesame")

        #expect(header.name == "Authorization")
        #expect(header.value == "Basic YWxhZGRpbjpvcGVuIHNlc2FtZQ==")
    }
}
