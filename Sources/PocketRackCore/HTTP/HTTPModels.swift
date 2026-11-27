import Foundation

public enum HTTPMethod: String, Sendable, CaseIterable, Hashable {
    case GET, HEAD, POST, PUT, DELETE, PATCH, OPTIONS
}

public struct HTTPStatus: Sendable, Equatable, Hashable {
    public let code: Int
    public let reasonPhrase: String

    public init(code: Int, reasonPhrase: String) {
        self.code = code
        self.reasonPhrase = reasonPhrase
    }

    public static let ok = HTTPStatus(code: 200, reasonPhrase: "OK")
    public static let created = HTTPStatus(code: 201, reasonPhrase: "Created")
    public static let noContent = HTTPStatus(code: 204, reasonPhrase: "No Content")
    public static let partialContent = HTTPStatus(code: 206, reasonPhrase: "Partial Content")
    public static let notModified = HTTPStatus(code: 304, reasonPhrase: "Not Modified")
    public static let badRequest = HTTPStatus(code: 400, reasonPhrase: "Bad Request")
    public static let unauthorized = HTTPStatus(code: 401, reasonPhrase: "Unauthorized")
    public static let forbidden = HTTPStatus(code: 403, reasonPhrase: "Forbidden")
    public static let notFound = HTTPStatus(code: 404, reasonPhrase: "Not Found")
    public static let methodNotAllowed = HTTPStatus(code: 405, reasonPhrase: "Method Not Allowed")
    public static let conflict = HTTPStatus(code: 409, reasonPhrase: "Conflict")
    public static let payloadTooLarge = HTTPStatus(code: 413, reasonPhrase: "Payload Too Large")
    public static let rangeNotSatisfiable = HTTPStatus(code: 416, reasonPhrase: "Range Not Satisfiable")
    public static let headersTooLarge = HTTPStatus(code: 431, reasonPhrase: "Request Header Fields Too Large")
    public static let internalServerError = HTTPStatus(code: 500, reasonPhrase: "Internal Server Error")
    public static let serviceUnavailable = HTTPStatus(code: 503, reasonPhrase: "Service Unavailable")
    public static let insufficientStorage = HTTPStatus(code: 507, reasonPhrase: "Insufficient Storage")
}

public struct HTTPHeaders: Sendable, Equatable {
    private var entries: [(key: String, value: String)] = []

    public init(_ dictionary: [String: String] = [:]) {
        for (k, v) in dictionary {
            self[k] = v
        }
    }

    public subscript(name: String) -> String? {
        get {
            let target = name.lowercased()
            return entries.last { $0.key.lowercased() == target }?.value
        }
        set {
            let target = name.lowercased()
            entries.removeAll { $0.key.lowercased() == target }
            if let newValue {
                entries.append((key: name, value: newValue))
            }
        }
    }

    public mutating func add(_ name: String, value: String) {
        entries.append((key: name, value: value))
    }

    public var all: [(key: String, value: String)] { entries }

    public var asDictionary: [String: String] {
        var result: [String: String] = [:]
        for entry in entries {
            result[entry.key] = entry.value
        }
        return result
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.entries.count == rhs.entries.count &&
        zip(lhs.entries, rhs.entries).allSatisfy {
            $0.key.lowercased() == $1.key.lowercased() && $0.value == $1.value
        }
    }
}

public enum HTTPRequestBody: Sendable {
    case data(Data)
    case tempFile(URL, size: UInt64)
}

public struct HTTPRequest: Sendable {
    public var method: HTTPMethod
    public var target: String
    public var path: String
    public var queryItems: [URLQueryItem]
    public var headers: HTTPHeaders
    public var body: HTTPRequestBody
    public var remoteAddress: String

    public init(
        method: HTTPMethod,
        target: String,
        headers: HTTPHeaders = HTTPHeaders(),
        body: HTTPRequestBody = .data(Data()),
        remoteAddress: String = "127.0.0.1"
    ) {
        self.method = method
        self.target = target
        let parts = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = String(parts.first ?? "/")
        self.path = rawPath.removingPercentEncoding ?? rawPath
        if parts.count == 2 {
            var comps = URLComponents()
            comps.percentEncodedQuery = String(parts[1])
            self.queryItems = comps.queryItems ?? []
        } else {
            self.queryItems = []
        }
        self.headers = headers
        self.body = body
        self.remoteAddress = remoteAddress
    }

    public var bodyData: Data {
        switch body {
        case .data(let data):
            return data
        case .tempFile(let url, _):
            return (try? Data(contentsOf: url)) ?? Data()
        }
    }

    public func queryValue(_ name: String) -> String? {
        queryItems.first { $0.name == name }?.value
    }

    public func cookieValue(_ name: String) -> String? {
        guard let cookieHeader = headers["Cookie"] else { return nil }
        for part in cookieHeader.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            let kv = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if kv.count == 2 && String(kv[0]) == name {
                return String(kv[1])
            }
        }
        return nil
    }
}

public enum HTTPResponseBody: Sendable {
    case data(Data)
    case fileStream(URL, offset: UInt64, length: UInt64, chunkSize: Int)

    public var contentLength: UInt64 {
        switch self {
        case .data(let data):
            return UInt64(data.count)
        case .fileStream(_, _, let length, _):
            return length
        }
    }

    public var dataOrEmpty: Data {
        switch self {
        case .data(let data):
            return data
        case .fileStream:
            return Data()
        }
    }
}

public struct HTTPResponse: Sendable {
    public var status: HTTPStatus
    public var headers: HTTPHeaders
    public var body: HTTPResponseBody
    public var suppressBody: Bool

    public init(
        status: HTTPStatus = .ok,
        headers: HTTPHeaders = HTTPHeaders(),
        body: HTTPResponseBody = .data(Data()),
        suppressBody: Bool = false
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.suppressBody = suppressBody
    }

    public static func text(_ string: String, status: HTTPStatus = .ok, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        var headers = HTTPHeaders()
        headers["Content-Type"] = contentType
        return HTTPResponse(status: status, headers: headers, body: .data(Data(string.utf8)))
    }

    public static func html(_ html: String, status: HTTPStatus = .ok) -> HTTPResponse {
        text(html, status: status, contentType: "text/html; charset=utf-8")
    }

    public static func json<T: Encodable>(status: HTTPStatus = .ok, body: T) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(body)) ?? Data("{}".utf8)
        var headers = HTTPHeaders()
        headers["Content-Type"] = "application/json; charset=utf-8"
        return HTTPResponse(status: status, headers: headers, body: .data(data))
    }

    public static func jsonError(status: HTTPStatus, code: String, message: String) -> HTTPResponse {
        struct ErrorPayload: Encodable {
            struct Inner: Encodable {
                let code: String
                let message: String
            }
            let error: Inner
        }
        return json(status: status, body: ErrorPayload(error: .init(code: code, message: message)))
    }
}
