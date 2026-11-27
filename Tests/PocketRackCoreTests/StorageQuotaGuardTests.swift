import Foundation
import Testing
@testable import PocketRackCore

private struct MockDiskProbe: DiskSpaceProbe {
    var availableBytes: UInt64
    var usedBytes: UInt64

    func availableCapacity(for url: URL) throws -> UInt64 {
        availableBytes
    }

    func directoryUsage(for url: URL) throws -> UInt64 {
        usedBytes
    }
}

@Suite("StorageQuotaGuard Tests")
struct StorageQuotaGuardTests {
    @Test("Permits writes within 100GB quota and above 15GB free floor")
    func permitsWriteWithinLimits() throws {
        let guardObj = StorageQuotaGuard(
            quotaBytes: 100 * 1024 * 1024 * 1024,
            minFreeFloorBytes: 15 * 1024 * 1024 * 1024,
            probe: MockDiskProbe(availableBytes: 200 * 1024 * 1024 * 1024, usedBytes: 10 * 1024 * 1024 * 1024)
        )
        try guardObj.validateWrite(additionalBytes: 1024 * 1024, rootURL: URL(fileURLWithPath: "/tmp"))
    }

    @Test("Rejects writes exceeding PocketRack 100GB quota")
    func rejectsWriteExceedingQuota() {
        let guardObj = StorageQuotaGuard(
            quotaBytes: 100 * 1024 * 1024 * 1024,
            minFreeFloorBytes: 15 * 1024 * 1024 * 1024,
            probe: MockDiskProbe(availableBytes: 200 * 1024 * 1024 * 1024, usedBytes: 100 * 1024 * 1024 * 1024 - 500)
        )
        #expect(throws: StorageQuotaError.quotaExceeded) {
            try guardObj.validateWrite(additionalBytes: 1024, rootURL: URL(fileURLWithPath: "/tmp"))
        }
    }

    @Test("Rejects writes crossing 15GB iPadOS free-space safety floor")
    func rejectsWriteCrossingSafetyFloor() {
        let guardObj = StorageQuotaGuard(
            quotaBytes: 100 * 1024 * 1024 * 1024,
            minFreeFloorBytes: 15 * 1024 * 1024 * 1024,
            probe: MockDiskProbe(availableBytes: 15 * 1024 * 1024 * 1024 + 100, usedBytes: 1024)
        )
        #expect(throws: StorageQuotaError.freeSpaceFloorReached) {
            try guardObj.validateWrite(additionalBytes: 1024, rootURL: URL(fileURLWithPath: "/tmp"))
        }
    }
}
