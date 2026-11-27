import Testing
@testable import PocketRackCore

@Suite("Bootstrap Tests")
struct BootstrapTests {
    @Test("Version is defined")
    func versionIsDefined() {
        #expect(!PocketRackVersion.current.isEmpty)
    }
}
