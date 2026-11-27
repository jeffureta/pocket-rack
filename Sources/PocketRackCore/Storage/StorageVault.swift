import Foundation

public enum StorageVaultError: Error, Equatable, Sendable {
    case pathTraversal
    case notFound
    case isDirectory
    case rangeNotSatisfiable
}

public struct VaultItem: Sendable, Codable, Equatable {
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modifiedAt: Date
    public let mimeType: String
}

public struct StorageVault: Sendable {
    public let rootURL: URL
    public let streamChunkSize: Int

    public init(rootURL: URL, streamChunkSize: Int = 256 * 1024) {
        self.rootURL = rootURL.resolvingSymlinksInPath().standardizedFileURL
        self.streamChunkSize = streamChunkSize
    }

    public func resolveSafePath(_ rawPath: String) throws -> URL {
        if rawPath.contains("\0") {
            throw StorageVaultError.pathTraversal
        }
        let decoded = rawPath.removingPercentEncoding ?? rawPath
        if decoded.contains("\0") {
            throw StorageVaultError.pathTraversal
        }

        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let components = trimmed.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if components.contains("..") || components.contains(".") {
            throw StorageVaultError.pathTraversal
        }

        let candidate = components.reduce(rootURL) { partial, segment in
            partial.appendingPathComponent(segment, isDirectory: false)
        }
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL

        let rootPath = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        if resolved.path != rootURL.path && !resolved.path.hasPrefix(rootPath) {
            throw StorageVaultError.pathTraversal
        }
        return resolved
    }

    public func serveStatic(path: String, requestHeaders: HTTPHeaders) throws -> HTTPResponse {
        var resolved = try resolveSafePath(path)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) else {
            throw StorageVaultError.notFound
        }
        if isDir.boolValue {
            let indexURL = resolved.appendingPathComponent("index.html")
            var indexDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: indexURL.path, isDirectory: &indexDir), !indexDir.boolValue {
                resolved = indexURL
            } else {
                throw StorageVaultError.isDirectory
            }
        }
        return try streamFileResponse(at: resolved, requestHeaders: requestHeaders)
    }

    public func streamFileResponse(at fileURL: URL, requestHeaders: HTTPHeaders) throws -> HTTPResponse {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir) else {
            throw StorageVaultError.notFound
        }
        guard !isDir.boolValue else {
            throw StorageVaultError.isDirectory
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let totalSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let modDate = (attrs[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let etag = "\"\(totalSize)-\(Int64(modDate.timeIntervalSince1970))\""

        var headers = HTTPHeaders()
        headers["Content-Type"] = Self.mimeType(for: fileURL.pathExtension)
        headers["Accept-Ranges"] = "bytes"
        headers["ETag"] = etag

        if let ifNoneMatch = requestHeaders["If-None-Match"], ifNoneMatch == etag {
            return HTTPResponse(status: .notModified, headers: headers, body: .data(Data()), suppressBody: true)
        }

        if let rangeHeader = requestHeaders["Range"], rangeHeader.lowercased().hasPrefix("bytes=") {
            guard let (start, end) = Self.parseRange(rangeHeader, totalSize: totalSize) else {
                var errHeaders = HTTPHeaders()
                errHeaders["Content-Range"] = "bytes */\(totalSize)"
                return HTTPResponse(status: .rangeNotSatisfiable, headers: errHeaders, body: .data(Data()))
            }
            let length = end - start + 1
            headers["Content-Range"] = "bytes \(start)-\(end)/\(totalSize)"
            return HTTPResponse(
                status: .partialContent,
                headers: headers,
                body: .fileStream(fileURL, offset: start, length: length, chunkSize: streamChunkSize)
            )
        }

        return HTTPResponse(
            status: .ok,
            headers: headers,
            body: .fileStream(fileURL, offset: 0, length: totalSize, chunkSize: streamChunkSize)
        )
    }

    public func listDirectory(relativePath: String) throws -> [VaultItem] {
        let dirURL = try resolveSafePath(relativePath)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw StorageVaultError.notFound
        }

        let contents = try FileManager.default.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        return contents.compactMap { url in
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let isDirectory = vals?.isDirectory ?? false
            let size = UInt64(max(0, vals?.fileSize ?? 0))
            let mod = vals?.contentModificationDate ?? Date()
            let rel = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
            return VaultItem(
                name: url.lastPathComponent,
                path: rel,
                isDirectory: isDirectory,
                size: size,
                modifiedAt: mod,
                mimeType: isDirectory ? "inode/directory" : Self.mimeType(for: url.pathExtension)
            )
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public func createDirectory(relativePath: String) throws {
        let target = try resolveSafePath(relativePath)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    }

    @discardableResult
    public func writeFile(relativePath: String, data: Data) throws -> VaultItem {
        let target = try resolveSafePath(relativePath)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let tempURL = parent.appendingPathComponent(".pocketrack-tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: target)
        }
        return try makeItem(for: target)
    }

    @discardableResult
    public func moveUploadedTempFile(_ tempURL: URL, toRelativePath relativePath: String) throws -> VaultItem {
        let target = try resolveSafePath(relativePath)
        let parent = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: tempURL)
        } else {
            try FileManager.default.moveItem(at: tempURL, to: target)
        }
        return try makeItem(for: target)
    }

    public func deleteItem(relativePath: String) throws {
        let target = try resolveSafePath(relativePath)
        guard target.path != rootURL.path else {
            throw StorageVaultError.pathTraversal
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            throw StorageVaultError.notFound
        }
        try FileManager.default.removeItem(at: target)
    }

    private func makeItem(for url: URL) throws -> VaultItem {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mod = (attrs[.modificationDate] as? Date) ?? Date()
        let rootPrefix = rootURL.path.hasSuffix("/") ? rootURL.path : rootURL.path + "/"
        let rel = url.path.hasPrefix(rootPrefix) ? String(url.path.dropFirst(rootPrefix.count)) : url.lastPathComponent
        return VaultItem(
            name: url.lastPathComponent,
            path: rel,
            isDirectory: false,
            size: size,
            modifiedAt: mod,
            mimeType: Self.mimeType(for: url.pathExtension)
        )
    }

    private static func parseRange(_ header: String, totalSize: UInt64) -> (UInt64, UInt64)? {
        guard totalSize > 0 else { return nil }
        let spec = String(header.dropFirst("bytes=".count)).trimmingCharacters(in: .whitespaces)
        guard !spec.contains(",") else { return nil }
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            let start = suffix >= totalSize ? 0 : totalSize - suffix
            return (start, totalSize - 1)
        }

        guard let start = UInt64(parts[0]), start < totalSize else { return nil }
        if parts[1].isEmpty {
            return (start, totalSize - 1)
        }
        guard let rawEnd = UInt64(parts[1]), rawEnd >= start else { return nil }
        return (start, min(rawEnd, totalSize - 1))
    }

    public static func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "txt", "md", "log", "csv": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "pdf": return "application/pdf"
        case "wasm": return "application/wasm"
        case "mp4": return "video/mp4"
        case "mp3": return "audio/mpeg"
        case "zip": return "application/zip"
        default: return "application/octet-stream"
        }
    }
}
