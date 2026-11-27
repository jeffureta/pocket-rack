import Foundation
import Testing
@testable import PocketRackCore

@Suite("StorageVault Tests")
struct StorageVaultTests {
    private func makeTempRoot() throws -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("pocketrack-vault-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    @Test("Blocks directory traversal and symlink escapes")
    func blocksTraversalAndSymlinks() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let outsideFile = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString).txt")
        try Data("secret".utf8).write(to: outsideFile)
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let symlinkURL = root.appendingPathComponent("escape.txt")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        let vault = StorageVault(rootURL: root)

        #expect(throws: StorageVaultError.pathTraversal) {
            _ = try vault.resolveSafePath("../etc/passwd")
        }
        #expect(throws: StorageVaultError.pathTraversal) {
            _ = try vault.resolveSafePath("%2e%2e/%2e%2e/secret")
        }
        #expect(throws: StorageVaultError.pathTraversal) {
            _ = try vault.resolveSafePath("bad\0path")
        }
        #expect(throws: StorageVaultError.pathTraversal) {
            _ = try vault.resolveSafePath("escape.txt")
        }
    }

    @Test("Serves static files with index.html fallback, ETag 304, and Range 206")
    func servesStaticETagAndRange() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let html = "<html><body>Hello PocketRack</body></html>"
        try Data(html.utf8).write(to: root.appendingPathComponent("index.html"))
        try Data("0123456789ABCDEF".utf8).write(to: root.appendingPathComponent("data.bin"))

        let vault = StorageVault(rootURL: root)
        let indexRes = try vault.serveStatic(path: "/", requestHeaders: HTTPHeaders())
        #expect(indexRes.status == .ok)
        #expect(indexRes.headers["Content-Type"]?.contains("text/html") == true)
        let etag = indexRes.headers["ETag"]
        #expect(etag != nil)

        var cacheHeaders = HTTPHeaders()
        cacheHeaders["If-None-Match"] = etag
        let notModified = try vault.serveStatic(path: "/", requestHeaders: cacheHeaders)
        #expect(notModified.status == .notModified)

        var rangeHeaders = HTTPHeaders()
        rangeHeaders["Range"] = "bytes=4-7"
        let rangeRes = try vault.serveStatic(path: "/data.bin", requestHeaders: rangeHeaders)
        #expect(rangeRes.status == .partialContent)
        #expect(rangeRes.headers["Content-Range"] == "bytes 4-7/16")
        if case .fileStream(let url, let offset, let length, _) = rangeRes.body {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            let slice = handle.readData(ofLength: Int(length))
            #expect(String(data: slice, encoding: .utf8) == "4567")
        } else {
            Issue.record("Expected .fileStream response body")
        }
    }

    @Test("Writes, lists, creates directories, and deletes files safely")
    func crudFileOperations() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = StorageVault(rootURL: root)
        try vault.createDirectory(relativePath: "assets")
        let written = try vault.writeFile(relativePath: "assets/app.js", data: Data("console.log(1);".utf8))
        #expect(written.size == 15)

        let listing = try vault.listDirectory(relativePath: "assets")
        #expect(listing.count == 1)
        #expect(listing.first?.name == "app.js")

        try vault.deleteItem(relativePath: "assets/app.js")
        let afterDelete = try vault.listDirectory(relativePath: "assets")
        #expect(afterDelete.isEmpty)
    }
}
