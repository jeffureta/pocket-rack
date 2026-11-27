import Foundation
import Testing
@testable import PocketRackCore

@Suite("RackRouter Tests")
struct RackRouterTests {
    @Test("Matches exact routes, named parameters, and trailing wildcards")
    func matchesRoutes() async throws {
        let router = RackRouter()
        await router.register(.GET, "/api/v1/health") { _ in
            HTTPResponse.json(status: .ok, body: ["status": "healthy"])
        }
        await router.register(.GET, "/api/v1/collections/:name/:id") { ctx in
            HTTPResponse.json(status: .ok, body: [
                "name": ctx.param("name") ?? "",
                "id": ctx.param("id") ?? "",
            ])
        }
        await router.register(.GET, "/api/v1/files/*path") { ctx in
            HTTPResponse.text(ctx.param("path") ?? "")
        }

        let healthReq = HTTPRequest(method: .GET, target: "/api/v1/health")
        let healthRes = try await router.handle(healthReq)
        #expect(healthRes.status == .ok)

        let docReq = HTTPRequest(method: .GET, target: "/api/v1/collections/notes/42")
        let docRes = try await router.handle(docReq)
        let docText = String(data: docRes.body.dataOrEmpty, encoding: .utf8) ?? ""
        #expect(docText.contains("\"notes\"") && docText.contains("\"42\""))

        let fileReq = HTTPRequest(method: .GET, target: "/api/v1/files/sites/blog/index.html")
        let fileRes = try await router.handle(fileReq)
        #expect(String(data: fileRes.body.dataOrEmpty, encoding: .utf8) == "sites/blog/index.html")
    }

    @Test("Returns 404 when no route matches and executes middleware in order")
    func executesMiddlewareAndNotFound() async throws {
        let router = RackRouter()
        await router.use { req, next in
            var res = try await next(req)
            res.headers["X-Rack-Middleware"] = "applied"
            return res
        }
        await router.register(.GET, "/ping") { _ in
            HTTPResponse.text("pong")
        }

        let okRes = try await router.handle(HTTPRequest(method: .GET, target: "/ping"))
        #expect(okRes.status == .ok)
        #expect(okRes.headers["X-Rack-Middleware"] == "applied")

        let missRes = try await router.handle(HTTPRequest(method: .GET, target: "/missing"))
        #expect(missRes.status == .notFound)
        #expect(missRes.headers["X-Rack-Middleware"] == "applied")
    }
}
