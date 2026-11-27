import Foundation
import Testing
@testable import PocketRackCore

@Suite("RackStore SQLite Tests")
struct RackStoreTests {
    @Test("Performs Collection CRUD with pagination in memory")
    func collectionCRUD() async throws {
        let store = try RackStore(path: ":memory:", profile: .balancedM2)

        let doc1 = try await store.createDocument(collection: "notes", id: nil, jsonString: "{\"title\":\"One\"}")
        let doc2 = try await store.createDocument(collection: "notes", id: "custom-2", jsonString: "{\"title\":\"Two\"}")
        #expect(!doc1.id.isEmpty)
        #expect(doc2.id == "custom-2")

        let fetched = try await store.getDocument(collection: "notes", id: "custom-2")
        #expect(fetched?.jsonString == "{\"title\":\"Two\"}")

        let updated = try await store.upsertDocument(collection: "notes", id: "custom-2", jsonString: "{\"title\":\"Two Updated\"}")
        #expect(updated.jsonString == "{\"title\":\"Two Updated\"}")

        let page1 = try await store.listDocuments(collection: "notes", limit: 1, offset: 0)
        let page2 = try await store.listDocuments(collection: "notes", limit: 1, offset: 1)
        #expect(page1.count == 1)
        #expect(page2.count == 1)
        #expect(page1.first?.id != page2.first?.id)

        let deleted = try await store.deleteDocument(collection: "notes", id: doc1.id)
        #expect(deleted)
        #expect(try await store.getDocument(collection: "notes", id: doc1.id) == nil)
    }

    @Test("Stores and expires KV entries by TTL")
    func kvStoreAndTTL() async throws {
        let store = try RackStore(path: ":memory:", profile: .balancedM2)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        try await store.setValue(key: "session_flag", value: "active", ttlSeconds: 60, now: t0)
        try await store.setValue(key: "permanent", value: "yes", ttlSeconds: nil, now: t0)

        let active = try await store.getValue(key: "session_flag", now: t0.addingTimeInterval(30))
        #expect(active?.value == "active")

        let expired = try await store.getValue(key: "session_flag", now: t0.addingTimeInterval(61))
        #expect(expired == nil)

        let keys = try await store.listKeys(now: t0.addingTimeInterval(61))
        #expect(keys.map(\.key) == ["permanent"])
    }

    @Test("Records webhooks and prunes oldest deliveries beyond maxWebhookEvents cap")
    func webhookRingPruning() async throws {
        var profile = CapacityProfile.balancedM2
        profile.maxWebhookEvents = 3
        let store = try RackStore(path: ":memory:", profile: profile)

        for idx in 1...5 {
            _ = try await store.recordWebhook(
                hook: "github",
                method: "POST",
                headers: ["X-Event": "push"],
                query: "",
                body: "{\"seq\":\(idx)}",
                remoteAddress: "192.168.1.50"
            )
        }

        let events = try await store.listWebhooks(hook: "github", limit: 10)
        #expect(events.count == 3)
        #expect(events.first?.body == "{\"seq\":5}")
        #expect(events.last?.body == "{\"seq\":3}")

        try await store.clearWebhooks(hook: "github")
        #expect(try await store.listWebhooks(hook: "github", limit: 10).isEmpty)
    }
}
