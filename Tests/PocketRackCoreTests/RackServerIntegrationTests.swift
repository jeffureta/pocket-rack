import CryptoKit
import Foundation
import Testing
@testable import PocketRackCore

@Suite("RackServer Live Loopback Integration Tests")
struct RackServerIntegrationTests {
    @Test("Serves static files, streams uploads/downloads with SHA256 integrity, CRUD APIs, and cookie auth over NWListener")
    func liveLoopbackEndToEnd() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("pocketrack-int-\(UUID().uuidString)", isDirectory: true)
        let siteDir = tempDir.appendingPathComponent("site", isDirectory: true)
        try FileManager.default.createDirectory(at: siteDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try Data("<h1>PocketRack Live</h1>".utf8).write(to: siteDir.appendingPathComponent("index.html"))
        let dbPath = tempDir.appendingPathComponent("rack.sqlite").path

        let config = RackConfiguration(
            port: 0,
            bonjourName: nil,
            rootURL: siteDir,
            databasePath: dbPath,
            authToken: "integration-secret-token",
            profile: .balancedM2,
            publicStaticReads: true,
            requireAuthForWebhooks: false
        )

        let app = try await RackApplication(configuration: config)
        let boundPort = try await app.start()
        defer { Task { await app.stop() } }

        #expect(boundPort > 0)
        let baseURL = URL(string: "http://127.0.0.1:\(boundPort)")!
        let sessionConfig = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: sessionConfig)

        // 1. Public static home page
        let (homeData, homeResp) = try await session.data(from: baseURL)
        #expect((homeResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: homeData, encoding: .utf8)?.contains("PocketRack Live") == true)

        // 2. Unauthorized file API check
        let (_, unauthResp) = try await session.data(from: baseURL.appendingPathComponent("api/v1/files"))
        #expect((unauthResp as? HTTPURLResponse)?.statusCode == 401)

        // 3. Streamed multi-chunk file upload & download SHA256 round-trip
        let payload = Data((0..<(400 * 1024)).map { UInt8($0 & 0xFF) })
        let expectedHash = SHA256.hash(data: payload)

        var putReq = URLRequest(url: baseURL.appendingPathComponent("api/v1/files/big.bin"))
        putReq.httpMethod = "PUT"
        putReq.setValue("Bearer integration-secret-token", forHTTPHeaderField: "Authorization")
        putReq.httpBody = payload
        let (_, putResp) = try await session.data(for: putReq)
        #expect((putResp as? HTTPURLResponse)?.statusCode == 201)

        var getReq = URLRequest(url: baseURL.appendingPathComponent("api/v1/files/big.bin"))
        getReq.setValue("Bearer integration-secret-token", forHTTPHeaderField: "Authorization")
        let (downloaded, getResp) = try await session.data(for: getReq)
        #expect((getResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(SHA256.hash(data: downloaded) == expectedHash)

        // 4. Admin cookie login flow
        var loginReq = URLRequest(url: baseURL.appendingPathComponent("_admin/auth/login"))
        loginReq.httpMethod = "POST"
        loginReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        loginReq.httpBody = Data("{\"token\":\"integration-secret-token\"}".utf8)
        let (_, loginResp) = try await session.data(for: loginReq)
        #expect((loginResp as? HTTPURLResponse)?.statusCode == 200)

        // Cookie stored in ephemeral URLSession allows subsequent /api/v1/health authorized response
        let (healthData, healthResp) = try await session.data(from: baseURL.appendingPathComponent("api/v1/health"))
        #expect((healthResp as? HTTPURLResponse)?.statusCode == 200)
        let healthText = String(data: healthData, encoding: .utf8) ?? ""
        #expect(healthText.contains("effectiveConnectionLimit"))
    }
}
