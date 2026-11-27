import CryptoKit
import Foundation
import Security

public struct AuthGate: Sendable {
    public static let sessionCookieName = "pocketrack_session"

    private let tokenData: Data
    private let sessionKey: SymmetricKey

    public init(token: String, sessionSecret: Data? = nil) {
        self.tokenData = Data(token.utf8)
        if let sessionSecret, !sessionSecret.isEmpty {
            self.sessionKey = SymmetricKey(data: SHA256.hash(data: sessionSecret))
        } else {
            self.sessionKey = SymmetricKey(data: SHA256.hash(data: Data("pocketrack-session:\(token)".utf8)))
        }
    }

    public static func generateToken(byteCount: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public func verifyToken(_ candidate: String) -> Bool {
        Self.constantTimeEquals(Data(candidate.utf8), tokenData)
    }

    public func isAuthorized(_ request: HTTPRequest, now: Date = Date()) -> Bool {
        if let auth = request.headers["Authorization"], auth.lowercased().hasPrefix("bearer ") {
            let candidate = String(auth.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            if verifyToken(candidate) { return true }
        }
        if let rackToken = request.headers["X-Rack-Token"], verifyToken(rackToken.trimmingCharacters(in: .whitespaces)) {
            return true
        }
        if let cookie = request.cookieValue(Self.sessionCookieName), verifySessionCookie(cookie, now: now) {
            return true
        }
        return false
    }

    public func makeSessionCookieHeader(ttlSeconds: TimeInterval = 86_400, now: Date = Date()) -> String {
        let expiresAt = Int64(now.timeIntervalSince1970 + ttlSeconds)
        let payload = Self.base64URLEncode(Data("v1.\(expiresAt)".utf8))
        let signature = Self.base64URLEncode(Data(HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: sessionKey)))
        let value = "\(payload).\(signature)"
        return "\(Self.sessionCookieName)=\(value); Path=/; HttpOnly; SameSite=Strict; Max-Age=\(Int(ttlSeconds))"
    }

    public func makeClearedCookieHeader() -> String {
        "\(Self.sessionCookieName)=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
    }

    public func verifySessionCookie(_ rawValue: String, now: Date = Date()) -> Bool {
        let parts = rawValue.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let payload = String(parts[0])
        guard let sigData = Self.base64URLDecode(String(parts[1])) else { return false }
        let expected = Data(HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: sessionKey))
        guard Self.constantTimeEquals(sigData, expected),
              let payloadData = Self.base64URLDecode(payload),
              let decoded = String(data: payloadData, encoding: .utf8) else {
            return false
        }
        let segments = decoded.split(separator: ".")
        guard segments.count == 2, segments[0] == "v1", let expiresAt = Int64(segments[1]) else {
            return false
        }
        return Int64(now.timeIntervalSince1970) <= expiresAt
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecode(_ string: String) -> Data? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = base64.count % 4
        if rem > 0 {
            base64 += String(repeating: "=", count: 4 - rem)
        }
        return Data(base64Encoded: base64)
    }
}
