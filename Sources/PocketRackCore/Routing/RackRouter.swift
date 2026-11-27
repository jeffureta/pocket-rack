import Foundation

public struct RouteContext: Sendable {
    public let request: HTTPRequest
    public let params: [String: String]

    public init(request: HTTPRequest, params: [String: String] = [:]) {
        self.request = request
        self.params = params
    }

    public func param(_ name: String) -> String? {
        params[name]
    }
}

public typealias RouteHandler = @Sendable (RouteContext) async throws -> HTTPResponse
public typealias RackMiddleware = @Sendable (HTTPRequest, @Sendable (HTTPRequest) async throws -> HTTPResponse) async throws -> HTTPResponse

public actor RackRouter {
    private enum Segment: Sendable {
        case literal(String)
        case param(String)
        case wildcard(String)
    }

    private struct RouteEntry: Sendable {
        let method: HTTPMethod
        let segments: [Segment]
        let handler: RouteHandler
    }

    private var routes: [RouteEntry] = []
    private var middlewares: [RackMiddleware] = []

    public init() {}

    public func use(_ middleware: @escaping RackMiddleware) {
        middlewares.append(middleware)
    }

    public func register(_ method: HTTPMethod, _ pattern: String, handler: @escaping RouteHandler) {
        let segments = Self.compile(pattern)
        routes.append(RouteEntry(method: method, segments: segments, handler: handler))
    }

    public func handle(_ request: HTTPRequest) async throws -> HTTPResponse {
        let currentRoutes = routes
        let currentMiddlewares = middlewares

        let terminal: @Sendable (HTTPRequest) async throws -> HTTPResponse = { req in
            for route in currentRoutes where route.method == req.method {
                if let params = Self.match(req.path, against: route.segments) {
                    return try await route.handler(RouteContext(request: req, params: params))
                }
            }
            return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "No route matches \(req.method.rawValue) \(req.path)")
        }

        let pipeline = currentMiddlewares.reversed().reduce(terminal) { next, middleware in
            { req in
                try await middleware(req, next)
            }
        }
        return try await pipeline(request)
    }

    private static func compile(_ pattern: String) -> [Segment] {
        let trimmed = pattern.split(separator: "/", omittingEmptySubsequences: true)
        return trimmed.map { raw in
            let s = String(raw)
            if s.hasPrefix(":") {
                return .param(String(s.dropFirst()))
            } else if s.hasPrefix("*") {
                return .wildcard(String(s.dropFirst()))
            } else {
                return .literal(s)
            }
        }
    }

    private static func match(_ path: String, against segments: [Segment]) -> [String: String]? {
        let pathParts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var params: [String: String] = [:]
        var idx = 0

        for (segIndex, segment) in segments.enumerated() {
            switch segment {
            case .literal(let expected):
                guard idx < pathParts.count, pathParts[idx] == expected else { return nil }
                idx += 1
            case .param(let name):
                guard idx < pathParts.count else { return nil }
                params[name] = pathParts[idx]
                idx += 1
            case .wildcard(let name):
                let rest = pathParts[idx...].joined(separator: "/")
                params[name] = rest
                return segIndex == segments.count - 1 ? params : nil
            }
        }

        return idx == pathParts.count ? params : nil
    }
}
