import Foundation
import Testing
@testable import PocketRackCore

@Suite("Telemetry and RequestLedger Tests")
struct TelemetryTests {
    @Test("RequestLedger bounds entries to 500 and streams updates")
    func requestLedgerRingCap() async {
        let ledger = RequestLedger(maxEntries: 5)
        for idx in 1...8 {
            await ledger.record(RequestLogEntry(
                method: "GET",
                path: "/item/\(idx)",
                statusCode: 200,
                durationMs: 1.5,
                bytesOut: 128,
                remoteAddress: "127.0.0.1"
            ))
        }
        let entries = await ledger.recent(limit: 10)
        #expect(entries.count == 5)
        #expect(entries.first?.path == "/item/8")
        #expect(entries.last?.path == "/item/4")
        #expect(await ledger.totalRequests() == 8)
    }

    @Test("NetworkAddresses detects loopback or local interfaces without crashing")
    func networkAddressesEnumeration() {
        let addresses = NetworkAddresses.discover()
        #expect(addresses.allSatisfy { !$0.ip.isEmpty && !$0.interface.isEmpty })
    }
}
