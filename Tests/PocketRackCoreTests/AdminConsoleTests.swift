import Foundation
import Testing
@testable import PocketRackCore

@Suite("AdminConsole Tests")
struct AdminConsoleTests {
    @Test("Renders self-contained offline HTML console with zero external CDN links")
    func rendersSelfContainedAdminHTML() {
        let html = AdminConsole.htmlDocument()
        #expect(html.contains("PocketRack"))
        #expect(html.contains("/_admin/auth/login"))
        #expect(html.contains("/api/v1/files"))
        #expect(!html.contains("https://cdn."))
        #expect(!html.contains("http://cdn."))
    }
}
