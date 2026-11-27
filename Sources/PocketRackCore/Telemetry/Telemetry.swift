import Darwin
import Foundation

public struct RequestLogEntry: Sendable, Codable, Identifiable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let method: String
    public let path: String
    public let statusCode: Int
    public let durationMs: Double
    public let bytesOut: UInt64
    public let remoteAddress: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: String,
        path: String,
        statusCode: Int,
        durationMs: Double,
        bytesOut: UInt64,
        remoteAddress: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.bytesOut = bytesOut
        self.remoteAddress = remoteAddress
    }
}

public actor RequestLedger {
    private let maxEntries: Int
    private var entries: [RequestLogEntry] = []
    private var totalCount: UInt64 = 0
    private var totalBytesOut: UInt64 = 0
    private var continuations: [UUID: AsyncStream<RequestLogEntry>.Continuation] = [:]

    public init(maxEntries: Int = 500) {
        self.maxEntries = max(1, maxEntries)
    }

    public func record(_ entry: RequestLogEntry) {
        totalCount += 1
        totalBytesOut += entry.bytesOut
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    public func recent(limit: Int = 100) -> [RequestLogEntry] {
        Array(entries.prefix(max(1, limit)))
    }

    public func totalRequests() -> UInt64 { totalCount }
    public func bytesServed() -> UInt64 { totalBytesOut }

    public func stream() -> AsyncStream<RequestLogEntry> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }
}

public struct TelemetrySnapshot: Sendable, Codable, Equatable {
    public let uptimeSeconds: TimeInterval
    public let totalRequests: UInt64
    public let bytesServed: UInt64
    public let activeConnections: Int
    public let effectiveConnectionLimit: Int
    public let thermalState: RackThermalState
    public let availableMemoryBytes: UInt64
    public let storageUsedBytes: UInt64
    public let storageQuotaBytes: UInt64
    public let availableVolumeBytes: UInt64
    public let minFreeFloorBytes: UInt64
    public let batteryLevel: Float?
    public let batteryCharging: Bool?
}

public enum NetworkKind: String, Sendable, Codable, Equatable {
    case lan
    case tailscale
    case loopback
    case other
}

public struct NetworkInterfaceAddress: Sendable, Codable, Equatable, Identifiable {
    public var id: String { "\(interface)-\(ip)" }
    public let interface: String
    public let ip: String
    public let kind: NetworkKind
}

public enum NetworkAddresses {
    public static func discover() -> [NetworkInterfaceAddress] {
        var result: [NetworkInterfaceAddress] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let first = ifaddrPtr else { return result }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(addr.pointee.sa_len)
            guard getnameinfo(addr, len, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                continue
            }
            let ip = String(decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            let name = String(cString: current.pointee.ifa_name)
            let kind = classify(interface: name, ip: ip)
            result.append(NetworkInterfaceAddress(interface: name, ip: ip, kind: kind))
        }
        return result
    }

    public static func classify(interface: String, ip: String) -> NetworkKind {
        if ip == "127.0.0.1" || interface.hasPrefix("lo") {
            return .loopback
        }
        if interface.hasPrefix("utun") && isTailscaleCGNAT(ip) {
            return .tailscale
        }
        if interface.hasPrefix("en") {
            return .lan
        }
        return .other
    }

    private static func isTailscaleCGNAT(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && parts[1] >= 64 && parts[1] <= 127
    }
}
