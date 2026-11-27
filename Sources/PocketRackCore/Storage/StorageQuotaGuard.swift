import Foundation

public enum StorageQuotaError: Error, Equatable, Sendable {
    case quotaExceeded
    case freeSpaceFloorReached
}

public protocol DiskSpaceProbe: Sendable {
    func availableCapacity(for url: URL) throws -> UInt64
    func directoryUsage(for url: URL) throws -> UInt64
}

public struct DefaultDiskSpaceProbe: DiskSpaceProbe {
    public init() {}

    public func availableCapacity(for url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return UInt64(important)
        }
        if let regular = values.volumeAvailableCapacity, regular > 0 {
            return UInt64(regular)
        }
        return 0
    }

    public func directoryUsage(for url: URL) throws -> UInt64 {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return 0 }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            let res = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if res?.isRegularFile == true, let size = res?.fileSize {
                total += UInt64(max(0, size))
            }
        }
        return total
    }
}

public struct StorageQuotaGuard: Sendable {
    public let quotaBytes: UInt64
    public let minFreeFloorBytes: UInt64
    private let probe: any DiskSpaceProbe

    public init(
        quotaBytes: UInt64 = CapacityProfile.balancedM2.storageQuotaBytes,
        minFreeFloorBytes: UInt64 = CapacityProfile.balancedM2.minFreeDiskFloorBytes,
        probe: any DiskSpaceProbe = DefaultDiskSpaceProbe()
    ) {
        self.quotaBytes = quotaBytes
        self.minFreeFloorBytes = minFreeFloorBytes
        self.probe = probe
    }

    public func validateWrite(additionalBytes: UInt64, rootURL: URL) throws {
        let used = try probe.directoryUsage(for: rootURL)
        if used + additionalBytes > quotaBytes {
            throw StorageQuotaError.quotaExceeded
        }
        let available = try probe.availableCapacity(for: rootURL)
        if available <= minFreeFloorBytes || (available - minFreeFloorBytes) < additionalBytes {
            throw StorageQuotaError.freeSpaceFloorReached
        }
    }

    public func usageSummary(for rootURL: URL) -> (usedBytes: UInt64, quotaBytes: UInt64, availableVolumeBytes: UInt64, minFreeFloorBytes: UInt64) {
        let used = (try? probe.directoryUsage(for: rootURL)) ?? 0
        let available = (try? probe.availableCapacity(for: rootURL)) ?? 0
        return (used, quotaBytes, available, minFreeFloorBytes)
    }
}
