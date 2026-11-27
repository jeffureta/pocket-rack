import Foundation

public enum HTTPCodecError: Error, Equatable, Sendable {
    case malformedRequest
    case unsupportedMethod
    case headersTooLarge
    case payloadTooLarge
}

public enum HTTPParseResult: Sendable {
    case needMoreData
    case complete(HTTPRequest, remainder: Data)
}

public struct HTTPRequestParser: Sendable {
    public let maxHeaderBytes: Int
    public let maxBodyBytes: Int

    private var buffer = Data()
    private var headerParsed = false
    private var parsedMethod: HTTPMethod = .GET
    private var parsedTarget: String = "/"
    private var parsedHeaders = HTTPHeaders()
    private var expectedContentLength: Int?
    private var isChunked = false

    public init(maxHeaderBytes: Int = 64 * 1024, maxBodyBytes: Int = 32 * 1024 * 1024) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    public mutating func feed(_ chunk: Data, remoteAddress: String = "127.0.0.1") throws -> HTTPParseResult {
        buffer.append(chunk)

        if !headerParsed {
            let separator = Data([13, 10, 13, 10]) // \r\n\r\n
            guard let range = buffer.range(of: separator) else {
                if buffer.count > maxHeaderBytes {
                    throw HTTPCodecError.headersTooLarge
                }
                return .needMoreData
            }

            if range.lowerBound > maxHeaderBytes {
                throw HTTPCodecError.headersTooLarge
            }

            let headerData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)
            try parseHeaderBlock(headerData)
            headerParsed = true
        }

        if isChunked {
            guard let (decodedBody, consumed) = try decodeChunked(buffer) else {
                return .needMoreData
            }
            let remainder = buffer.subdata(in: consumed..<buffer.count)
            let req = HTTPRequest(
                method: parsedMethod,
                target: parsedTarget,
                headers: parsedHeaders,
                body: .data(decodedBody),
                remoteAddress: remoteAddress
            )
            reset()
            return .complete(req, remainder: remainder)
        }

        let length = expectedContentLength ?? 0
        if length > maxBodyBytes {
            throw HTTPCodecError.payloadTooLarge
        }
        if buffer.count < length {
            return .needMoreData
        }

        let bodyData = length > 0 ? buffer.subdata(in: 0..<length) : Data()
        let remainder = length < buffer.count ? buffer.subdata(in: length..<buffer.count) : Data()
        let req = HTTPRequest(
            method: parsedMethod,
            target: parsedTarget,
            headers: parsedHeaders,
            body: .data(bodyData),
            remoteAddress: remoteAddress
        )
        reset()
        return .complete(req, remainder: remainder)
    }

    private mutating func parseHeaderBlock(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw HTTPCodecError.malformedRequest
        }
        let lines = text.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            throw HTTPCodecError.malformedRequest
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            throw HTTPCodecError.malformedRequest
        }
        guard let method = HTTPMethod(rawValue: String(parts[0]).uppercased()) else {
            throw HTTPCodecError.unsupportedMethod
        }
        parsedMethod = method
        parsedTarget = String(parts[1])
        parsedHeaders = HTTPHeaders()

        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                throw HTTPCodecError.malformedRequest
            }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            parsedHeaders.add(name, value: value)
        }

        if let te = parsedHeaders["Transfer-Encoding"]?.lowercased(), te.contains("chunked") {
            isChunked = true
        } else if let cl = parsedHeaders["Content-Length"] {
            guard let len = Int(cl), len >= 0 else {
                throw HTTPCodecError.malformedRequest
            }
            if len > maxBodyBytes {
                throw HTTPCodecError.payloadTooLarge
            }
            expectedContentLength = len
        }
    }

    private func decodeChunked(_ data: Data) throws -> (Data, Int)? {
        var cursor = 0
        var output = Data()
        let crlf = Data([13, 10])

        while true {
            guard let lineEnd = data.range(of: crlf, in: cursor..<data.count) else {
                return nil
            }
            let sizeLineData = data.subdata(in: cursor..<lineEnd.lowerBound)
            guard let sizeLine = String(data: sizeLineData, encoding: .ascii)?
                .split(separator: ";").first?
                .trimmingCharacters(in: .whitespaces),
                  let chunkSize = Int(sizeLine, radix: 16),
                  chunkSize >= 0 else {
                throw HTTPCodecError.malformedRequest
            }

            cursor = lineEnd.upperBound
            if chunkSize == 0 {
                // Require final CRLF after 0-length terminator
                guard data.count >= cursor + 2,
                      data[cursor] == 13,
                      data[cursor + 1] == 10 else {
                    return nil
                }
                return (output, cursor + 2)
            }

            if output.count + chunkSize > maxBodyBytes {
                throw HTTPCodecError.payloadTooLarge
            }
            guard data.count >= cursor + chunkSize + 2 else {
                return nil
            }
            output.append(data.subdata(in: cursor..<(cursor + chunkSize)))
            guard data[cursor + chunkSize] == 13, data[cursor + chunkSize + 1] == 10 else {
                throw HTTPCodecError.malformedRequest
            }
            cursor += chunkSize + 2
        }
    }

    private mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        headerParsed = false
        expectedContentLength = nil
        isChunked = false
    }
}

public enum HTTPResponseSerializer {
    public static func serializeHead(for response: HTTPResponse) -> Data {
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.contentLength)"
        if headers["X-Content-Type-Options"] == nil {
            headers["X-Content-Type-Options"] = "nosniff"
        }
        if headers["X-Frame-Options"] == nil {
            headers["X-Frame-Options"] = "SAMEORIGIN"
        }
        if headers["Connection"] == nil {
            headers["Connection"] = "close"
        }

        var head = "HTTP/1.1 \(response.status.code) \(response.status.reasonPhrase)\r\n"
        for (key, value) in headers.all {
            head += "\(key): \(value)\r\n"
        }
        head += "\r\n"
        return Data(head.utf8)
    }
}
