import Foundation
import Testing
@testable import PocketRackCore

private struct MockSystemResourceProbe: SystemResourceProbe {
    var availableMemoryBytes: UInt64
    var thermalState: RackThermalState
    var batteryLevel: Float?
    var batteryCharging: Bool?
}

@Suite("CapacityGovernor Tests")
struct CapacityGovernorTests {
    @Test("Balanced M2 profile matches iPad Air M2 defaults")
    func balancedM2ProfileMatchesSpec() {
        let profile = CapacityProfile.balancedM2
        #expect(profile.maxConcurrentConnections == 64)
        #expect(profile.streamChunkSizeBytes == 256 * 1024)
        #expect(profile.maxJSONBodyBytes == 32 * 1024 * 1024)
        #expect(profile.maxFileUploadBytes == 4 * 1024 * 1024 * 1024)
        #expect(profile.minMemoryHeadroomBytes == 256 * 1024 * 1024)
        #expect(profile.sqliteCacheKB == 16_000)
        #expect(profile.sqliteMmapBytes == 64 * 1024 * 1024)
        #expect(profile.maxWebhookEvents == 2_000)
        #expect(profile.storageQuotaBytes == 100 * 1024 * 1024 * 1024)
        #expect(profile.minFreeDiskFloorBytes == 15 * 1024 * 1024 * 1024)
    }

    @Test("Scales effective socket limit down across thermal states")
    func scalesSocketsByThermalState() async {
        let probe = MockSystemResourceProbe(availableMemoryBytes: 2 * 1024 * 1024 * 1024, thermalState: .nominal)
        let governor = CapacityGovernor(profile: .balancedM2, probe: probe)

        #expect(await governor.effectiveConnectionLimit() == 64)

        await governor.updateProbe(MockSystemResourceProbe(availableMemoryBytes: 2 * 1024 * 1024 * 1024, thermalState: .fair))
        #expect(await governor.effectiveConnectionLimit() == 32)

        await governor.updateProbe(MockSystemResourceProbe(availableMemoryBytes: 2 * 1024 * 1024 * 1024, thermalState: .serious))
        #expect(await governor.effectiveConnectionLimit() == 16)

        await governor.updateProbe(MockSystemResourceProbe(availableMemoryBytes: 2 * 1024 * 1024 * 1024, thermalState: .critical))
        #expect(await governor.effectiveConnectionLimit() == 4)
    }

    @Test("Sheds connections with 503 when socket limit reached or memory headroom below 256MB")
    func shedsLoadOnCapacityOrMemoryPressure() async {
        var profile = CapacityProfile.balancedM2
        profile.maxConcurrentConnections = 2
        let healthyProbe = MockSystemResourceProbe(availableMemoryBytes: 1024 * 1024 * 1024, thermalState: .nominal)
        let governor = CapacityGovernor(profile: profile, probe: healthyProbe)

        #expect(await governor.acquireSlot() == .admitted)
        #expect(await governor.acquireSlot() == .admitted)
        #expect(await governor.acquireSlot() == .rejected(reason: "connection_limit"))

        await governor.releaseSlot()
        await governor.updateProbe(MockSystemResourceProbe(availableMemoryBytes: 128 * 1024 * 1024, thermalState: .nominal))
        #expect(await governor.acquireSlot() == .rejected(reason: "memory_pressure"))
    }
}
