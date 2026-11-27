import Foundation
import Testing
@testable import PocketRackCore

@Suite("HTTPCodec Tests")
struct HTTPCodecTests {
    @Test("Parses simple GET request with query parameters and case-insensitive headers")
    func parsesSimpleGET() throws {
        let raw = Data("GET /api/v1/files?path=%2Fdocs&limit=10 HTTP/1.1\r\nHost: ipad.local:8080\r\nX-Custom-Header: Alpha\r\n\r\n".utf8)
        var parser = HTTPRequestParser()
        let result = try parser.feed(raw)

        guard case .complete(let request, _) = result else {
            Issue.record("Expected complete request")
            return
        }
        #expect(request.method == .GET)
        #expect(request.path == "/api/v1/files")
        #expect(request.queryValue("path") == "/docs")
        #expect(request.queryValue("limit") == "10")
        #expect(request.headers["host"] == "ipad.local:8080")
        #expect(request.headers["x-custom-header"] == "Alpha")
    }

    @Test("Reassembles incremental TCP chunks with Content-Length body")
    func reassemblesIncrementalChunks() throws {
        let part1 = Data("POST /api/v1/collections/notes HTTP/1.1\r\nContent-Type: application/json\r\n".utf8)
        let part2 = Data("Content-Length: 17\r\n\r\n{\"title\":".utf8)
        let part3 = Data("\"hello\"}".utf8)

        var parser = HTTPRequestParser()
        guard case .needMoreData = try parser.feed(part1) else {
            Issue.record("Expected needMoreData after part1")
            return
        }
        guard case .needMoreData = try parser.feed(part2) else {
            Issue.record("Expected needMoreData after part2")
            return
        }
        guard case .complete(let req, let remainder) = try parser.feed(part3) else {
            Issue.record("Expected complete after part3")
            return
        }
        #expect(remainder.isEmpty)
        #expect(req.method == .POST)
        #expect(String(data: req.bodyData, encoding: .utf8) == "{\"title\":\"hello\"}")
    }

    @Test("Decodes Transfer-Encoding chunked body")
    func decodesChunkedBody() throws {
        let raw = Data("POST /api/v1/webhooks/test HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
        var parser = HTTPRequestParser()
        guard case .complete(let req, _) = try parser.feed(raw) else {
            Issue.record("Expected complete chunked request")
            return
        }
        #expect(String(data: req.bodyData, encoding: .utf8) == "hello world")
    }

    @Test("Rejects oversized headers with 431")
    func rejectsOversizedHeaders() {
        let hugeHeader = String(repeating: "a", count: 70 * 1024)
        let raw = Data("GET / HTTP/1.1\r\nX-Huge: \(hugeHeader)\r\n\r\n".utf8)
        var parser = HTTPRequestParser(maxHeaderBytes: 64 * 1024)

        #expect(throws: HTTPCodecError.headersTooLarge) {
            _ = try parser.feed(raw)
        }
    }

    @Test("Rejects oversized body with 413")
    func rejectsOversizedBody() {
        let raw = Data("POST /api/v1/kv/k HTTP/1.1\r\nContent-Length: 1024\r\n\r\n".utf8)
        var parser = HTTPRequestParser(maxBodyBytes: 512)

        #expect(throws: HTTPCodecError.payloadTooLarge) {
            _ = try parser.feed(raw)
        }
    }

    @Test("Rejects malformed request line with 400")
    func rejectsMalformedRequestLine() {
        let raw = Data("BADREQUESTLINE\r\n\r\n".utf8)
        var parser = HTTPRequestParser()

        #expect(throws: HTTPCodecError.malformedRequest) {
            _ = try parser.feed(raw)
        }
    }

    @Test("Serializes response with security headers, ETag, and Content-Length")
    func serializesResponseWithSecurityHeaders() {
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/json"
        headers["ETag"] = "\"abc123\""
        let response = HTTPResponse(status: .ok, headers: headers, body: .data(Data("{\"ok\":true}".utf8)))
        let serialized = HTTPResponseSerializer.serializeHead(for: response)
        let text = String(data: serialized, encoding: .utf8) ?? ""

        #expect(text.contains("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Length: 11\r\n"))
        #expect(text.contains("X-Content-Type-Options: nosniff\r\n"))
        #expect(text.contains("X-Frame-Options: SAMEORIGIN\r\n"))
        #expect(text.contains("ETag: \"abc123\"\r\n"))
    }
}
