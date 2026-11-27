import Foundation
import Testing
@testable import PocketRackCore

private struct TestDiskProbe: DiskSpaceProbe {
    var availableBytes: UInt64
    var usedBytes: UInt64

    func availableCapacity(for url: URL) throws -> UInt64 { availableBytes }
    func directoryUsage(for url: URL) throws -> UInt64 { usedBytes }
}

@Suite("RackAPIHandlers Tests")
struct RackAPIHandlersTests {
    @Test("Enforces auth on protected API routes and serves public static site")
    func enforcesAuthAndServesStatic() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pocketrack-api-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<h1>PocketRack</h1>".utf8).write(to: root.appendingPathComponent("index.html"))

        let store = try RackStore(path: ":memory:", profile: .balancedM2)
        let vault = StorageVault(rootURL: root)
        let quota = StorageQuotaGuard(probe: TestDiskProbe(availableBytes: 200 * 1024 * 1024 * 1024, usedBytes: 0))
        let governor = CapacityGovernor(profile: .balancedM2)
        let auth = AuthGate(token: "test-token")
        let router = RackRouter()

        await RackAPIHandlers.registerAll(
            on: router,
            auth: auth,
            vault: vault,
            quota: quota,
            store: store,
            governor: governor,
            publicStaticReads: true,
            requireAuthForWebhooks: false
        )

        // Static site read succeeds without auth
        let homeRes = try await router.handle(HTTPRequest(method: .GET, target: "/"))
        #expect(homeRes.status == .ok)

        // Protected API fails without token
        let unauthFiles = try await router.handle(HTTPRequest(method: .GET, target: "/api/v1/files"))
        #expect(unauthFiles.status == .unauthorized)

        // Protected collection CRUD succeeds with Bearer token
        var headers = HTTPHeaders()
        headers["Authorization"] = "Bearer test-token"
        let createReq = HTTPRequest(
            method: .POST,
            target: "/api/v1/collections/tasks",
            headers: headers,
            body: .data(Data("{\"done\":false}".utf8))
        )
        let createRes = try await router.handle(createReq)
        #expect(createRes.status == .created)

        let listRes = try await router.handle(HTTPRequest(method: .GET, target: "/api/v1/collections/tasks", headers: headers))
        #expect(listRes.status == .ok)
        let bodyText = String(data: listRes.body.dataOrEmpty, encoding: .utf8) ?? ""
        #expect(bodyText.contains("done") && bodyText.contains("false"))
    }

    @Test("Returns 507 Insufficient Storage when quota or free-space floor is exceeded")
    func returns507WhenQuotaExceeded() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pocketrack-507-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try RackStore(path: ":memory:", profile: .balancedM2)
        let vault = StorageVault(rootURL: root)
        let quota = StorageQuotaGuard(
            quotaBytes: 100 * 1024 * 1024 * 1024,
            minFreeFloorBytes: 15 * 1024 * 1024 * 1024,
            probe: TestDiskProbe(availableBytes: 10 * 1024 * 1024 * 1024, usedBytes: 0)
        )
        let governor = CapacityGovernor(profile: .balancedM2)
        let auth = AuthGate(token: "test-token")
        let router = RackRouter()

        await RackAPIHandlers.registerAll(
            on: router,
            auth: auth,
            vault: vault,
            quota: quota,
            store: store,
            governor: governor
        )

        var headers = HTTPHeaders()
        headers["Authorization"] = "Bearer test-token"
        let uploadReq = HTTPRequest(
            method: .PUT,
            target: "/api/v1/files/big.txt",
            headers: headers,
            body: .data(Data("hello".utf8))
        )
        let res = try await router.handle(uploadReq)
        #expect(res.status == .insufficientStorage)
    }
}
