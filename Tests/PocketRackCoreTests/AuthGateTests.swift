import Foundation
import Testing
@testable import PocketRackCore

@Suite("AuthGate Tests")
struct AuthGateTests {
    @Test("Validates constant-time Bearer and X-Rack-Token headers")
    func validatesBearerAndRackToken() {
        let gate = AuthGate(token: "secret-rack-token-1234", sessionSecret: Data("session-signing-key".utf8))

        var bearerHeaders = HTTPHeaders()
        bearerHeaders["Authorization"] = "Bearer secret-rack-token-1234"
        let bearerReq = HTTPRequest(method: .GET, target: "/api/v1/files", headers: bearerHeaders)
        #expect(gate.isAuthorized(bearerReq))

        var rackHeaders = HTTPHeaders()
        rackHeaders["X-Rack-Token"] = "secret-rack-token-1234"
        let rackReq = HTTPRequest(method: .GET, target: "/api/v1/files", headers: rackHeaders)
        #expect(gate.isAuthorized(rackReq))

        var badHeaders = HTTPHeaders()
        badHeaders["Authorization"] = "Bearer wrong-token"
        let badReq = HTTPRequest(method: .GET, target: "/api/v1/files", headers: badHeaders)
        #expect(!gate.isAuthorized(badReq))
    }

    @Test("Issues and validates CryptoKit HMAC session cookies and rejects tampering or expiry")
    func validatesHMACSessionCookie() throws {
        let gate = AuthGate(token: "top-secret", sessionSecret: Data("hmac-key-32-bytes-long-enough-ok".utf8))
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let cookieHeaderValue = gate.makeSessionCookieHeader(ttlSeconds: 3600, now: now)
        #expect(cookieHeaderValue.contains("pocketrack_session="))
        #expect(cookieHeaderValue.contains("HttpOnly"))
        #expect(cookieHeaderValue.contains("SameSite=Strict"))

        let tokenPart = String(cookieHeaderValue.split(separator: ";").first!.dropFirst("pocketrack_session=".count))

        var reqHeaders = HTTPHeaders()
        reqHeaders["Cookie"] = "pocketrack_session=\(tokenPart)"
        let validReq = HTTPRequest(method: .GET, target: "/_admin", headers: reqHeaders)
        #expect(gate.isAuthorized(validReq, now: now.addingTimeInterval(1800)))
        #expect(!gate.isAuthorized(validReq, now: now.addingTimeInterval(4000)))

        // Tamper with payload
        var tamperedHeaders = HTTPHeaders()
        tamperedHeaders["Cookie"] = "pocketrack_session=tampered.\(tokenPart.split(separator: ".").last ?? "")"
        let tamperedReq = HTTPRequest(method: .GET, target: "/_admin", headers: tamperedHeaders)
        #expect(!gate.isAuthorized(tamperedReq, now: now))
    }

    @Test("Generates high-entropy random tokens")
    func generatesRandomTokens() {
        let t1 = AuthGate.generateToken()
        let t2 = AuthGate.generateToken()
        #expect(t1.count >= 32)
        #expect(t1 != t2)
    }
}
