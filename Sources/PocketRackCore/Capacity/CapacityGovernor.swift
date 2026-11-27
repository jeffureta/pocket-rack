import Darwin
import Foundation

public enum RackThermalState: String, Sendable, Codable, CaseIterable {
    case nominal
    case fair
    case serious
    case critical

    public static var currentProcess: RackThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

public protocol SystemResourceProbe: Sendable {
    var availableMemoryBytes: UInt64 { get }
    var thermalState: RackThermalState { get }
    var batteryLevel: Float? { get }
    var batteryCharging: Bool? { get }
}

public struct DefaultSystemResourceProbe: SystemResourceProbe {
    public init() {}

    public var availableMemoryBytes: UInt64 {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        return UInt64(os_proc_available_memory())
        #else
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kerr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if kerr == KERN_SUCCESS {
            let pageSize = UInt64(getpagesize())
            return UInt64(stats.free_count + stats.inactive_count) * pageSize
        }
        return 1024 * 1024 * 1024
        #endif
    }

    public var thermalState: RackThermalState {
        RackThermalState.currentProcess
    }

    public var batteryLevel: Float? { nil }
    public var batteryCharging: Bool? { nil }
}

public enum CapacityPreset: String, Sendable, Codable, CaseIterable {
    case eco
    case balancedM2
    case performanceM2

    public var displayName: String {
        switch self {
        case .eco: return "Eco Longevity"
        case .balancedM2: return "Balanced M2 (Recommended)"
        case .performanceM2: return "Performance M2"
        }
    }
}

public struct CapacityProfile: Sendable, Codable, Equatable {
    public var preset: CapacityPreset
    public var maxConcurrentConnections: Int
    public var streamChunkSizeBytes: Int
    public var maxJSONBodyBytes: Int
    public var maxFileUploadBytes: UInt64
    public var minMemoryHeadroomBytes: UInt64
    public var sqliteCacheKB: Int
    public var sqliteMmapBytes: UInt64
    public var maxWebhookEvents: Int
    public var storageQuotaBytes: UInt64
    public var minFreeDiskFloorBytes: UInt64

    public init(
        preset: CapacityPreset = .balancedM2,
        maxConcurrentConnections: Int = 64,
        streamChunkSizeBytes: Int = 256 * 1024,
        maxJSONBodyBytes: Int = 32 * 1024 * 1024,
        maxFileUploadBytes: UInt64 = 4 * 1024 * 1024 * 1024,
        minMemoryHeadroomBytes: UInt64 = 256 * 1024 * 1024,
        sqliteCacheKB: Int = 16_000,
        sqliteMmapBytes: UInt64 = 64 * 1024 * 1024,
        maxWebhookEvents: Int = 2_000,
        storageQuotaBytes: UInt64 = 100 * 1024 * 1024 * 1024,
        minFreeDiskFloorBytes: UInt64 = 15 * 1024 * 1024 * 1024
    ) {
        self.preset = preset
        self.maxConcurrentConnections = maxConcurrentConnections
        self.streamChunkSizeBytes = streamChunkSizeBytes
        self.maxJSONBodyBytes = maxJSONBodyBytes
        self.maxFileUploadBytes = maxFileUploadBytes
        self.minMemoryHeadroomBytes = minMemoryHeadroomBytes
        self.sqliteCacheKB = sqliteCacheKB
        self.sqliteMmapBytes = sqliteMmapBytes
        self.maxWebhookEvents = maxWebhookEvents
        self.storageQuotaBytes = storageQuotaBytes
        self.minFreeDiskFloorBytes = minFreeDiskFloorBytes
    }

    public static let eco = CapacityProfile(
        preset: .eco,
        maxConcurrentConnections: 24,
        streamChunkSizeBytes: 64 * 1024,
        maxJSONBodyBytes: 8 * 1024 * 1024,
        maxFileUploadBytes: 1 * 1024 * 1024 * 1024,
        minMemoryHeadroomBytes: 384 * 1024 * 1024,
        sqliteCacheKB: 8_000,
        sqliteMmapBytes: 16 * 1024 * 1024,
        maxWebhookEvents: 500,
        storageQuotaBytes: 32 * 1024 * 1024 * 1024,
        minFreeDiskFloorBytes: 25 * 1024 * 1024 * 1024
    )

    public static let balancedM2 = CapacityProfile()

    public static let performanceM2 = CapacityProfile(
        preset: .performanceM2,
        maxConcurrentConnections: 128,
        streamChunkSizeBytes: 512 * 1024,
        maxJSONBodyBytes: 64 * 1024 * 1024,
        maxFileUploadBytes: 10 * 1024 * 1024 * 1024,
        minMemoryHeadroomBytes: 192 * 1024 * 1024,
        sqliteCacheKB: 64_000,
        sqliteMmapBytes: 256 * 1024 * 1024,
        maxWebhookEvents: 5_000,
        storageQuotaBytes: 250 * 1024 * 1024 * 1024,
        minFreeDiskFloorBytes: 15 * 1024 * 1024 * 1024
    )
}

public enum AdmissionDecision: Sendable, Equatable {
    case admitted
    case rejected(reason: String)
}

public actor CapacityGovernor {
    public private(set) var profile: CapacityProfile
    private var probe: any SystemResourceProbe
    private var activeConnections: Int = 0

    public init(profile: CapacityProfile = .balancedM2, probe: any SystemResourceProbe = DefaultSystemResourceProbe()) {
        self.profile = profile
        self.probe = probe
    }

    public func updateProfile(_ newProfile: CapacityProfile) {
        self.profile = newProfile
    }

    public func updateProbe(_ newProbe: any SystemResourceProbe) {
        self.probe = newProbe
    }

    public func effectiveConnectionLimit() -> Int {
        let base = max(1, profile.maxConcurrentConnections)
        switch probe.thermalState {
        case .nominal:
            return base
        case .fair:
            return max(1, base / 2)
        case .serious:
            return max(1, base / 4)
        case .critical:
            return max(1, min(4, base))
        }
    }

    public func currentActiveConnections() -> Int {
        activeConnections
    }

    public func currentSnapshot() -> (active: Int, limit: Int, memoryHeadroomBytes: UInt64, thermal: RackThermalState, batteryLevel: Float?, batteryCharging: Bool?) {
        (
            activeConnections,
            effectiveConnectionLimit(),
            probe.availableMemoryBytes,
            probe.thermalState,
            probe.batteryLevel,
            probe.batteryCharging
        )
    }

    public func acquireSlot() -> AdmissionDecision {
        if probe.availableMemoryBytes < profile.minMemoryHeadroomBytes {
            return .rejected(reason: "memory_pressure")
        }
        let limit = effectiveConnectionLimit()
        if activeConnections >= limit {
            return .rejected(reason: "connection_limit")
        }
        activeConnections += 1
        return .admitted
    }

    public func releaseSlot() {
        if activeConnections > 0 {
            activeConnections -= 1
        }
    }
}
