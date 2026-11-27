import Foundation

public typealias HealthSnapshotHandler = @Sendable (_ authorized: Bool) async -> HTTPResponse
public typealias LogsHandler = @Sendable () async -> HTTPResponse

public enum RackAPIHandlers {
    public static func registerAll(
        on router: RackRouter,
        auth: AuthGate,
        vault: StorageVault,
        quota: StorageQuotaGuard,
        store: RackStore,
        governor: CapacityGovernor,
        publicStaticReads: Bool = true,
        requireAuthForWebhooks: Bool = false,
        healthHandler: HealthSnapshotHandler? = nil,
        logsHandler: LogsHandler? = nil
    ) async {
        // MARK: - Auth Session Login/Logout
        await router.register(.POST, "/_admin/auth/login") { ctx in
            struct LoginPayload: Decodable { let token: String? }
            let payload = try? JSONDecoder().decode(LoginPayload.self, from: ctx.request.bodyData)
            guard let candidate = payload?.token, auth.verifyToken(candidate) else {
                return HTTPResponse.jsonError(status: .unauthorized, code: "invalid_token", message: "Invalid access token.")
            }
            var res = HTTPResponse.json(status: .ok, body: ["authenticated": true])
            res.headers["Set-Cookie"] = auth.makeSessionCookieHeader()
            return res
        }

        await router.register(.POST, "/_admin/auth/logout") { _ in
            var res = HTTPResponse.json(status: .ok, body: ["authenticated": false])
            res.headers["Set-Cookie"] = auth.makeClearedCookieHeader()
            return res
        }

        // MARK: - Health Telemetry
        await router.register(.GET, "/api/v1/health") { ctx in
            let authorized = auth.isAuthorized(ctx.request)
            if let healthHandler {
                return await healthHandler(authorized)
            }
            let snap = await governor.currentSnapshot()
            let disk = quota.usageSummary(for: vault.rootURL)
            if !authorized {
                return HTTPResponse.json(status: .ok, body: ["status": "healthy", "version": PocketRackVersion.current])
            }
            struct FullHealth: Encodable {
                let status: String
                let version: String
                let activeConnections: Int
                let effectiveConnectionLimit: Int
                let thermalState: String
                let availableMemoryBytes: UInt64
                let storageUsedBytes: UInt64
                let storageQuotaBytes: UInt64
                let volumeFreeBytes: UInt64
                let minFreeFloorBytes: UInt64
            }
            return HTTPResponse.json(status: .ok, body: FullHealth(
                status: "healthy",
                version: PocketRackVersion.current,
                activeConnections: snap.active,
                effectiveConnectionLimit: snap.limit,
                thermalState: snap.thermal.rawValue,
                availableMemoryBytes: snap.memoryHeadroomBytes,
                storageUsedBytes: disk.usedBytes,
                storageQuotaBytes: disk.quotaBytes,
                volumeFreeBytes: disk.availableVolumeBytes,
                minFreeFloorBytes: disk.minFreeFloorBytes
            ))
        }

        // MARK: - Files API
        await router.register(.GET, "/api/v1/files") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let path = ctx.request.queryValue("path") ?? ""
            do {
                let items = try vault.listDirectory(relativePath: path)
                let disk = quota.usageSummary(for: vault.rootURL)
                struct Listing: Encodable {
                    let path: String
                    let items: [VaultItem]
                    let usedBytes: UInt64
                    let quotaBytes: UInt64
                    let availableVolumeBytes: UInt64
                }
                return HTTPResponse.json(status: .ok, body: Listing(
                    path: path,
                    items: items,
                    usedBytes: disk.usedBytes,
                    quotaBytes: disk.quotaBytes,
                    availableVolumeBytes: disk.availableVolumeBytes
                ))
            } catch {
                return mapVaultError(error)
            }
        }

        await router.register(.POST, "/api/v1/files/mkdir") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            struct MkdirBody: Decodable { let path: String }
            guard let body = try? JSONDecoder().decode(MkdirBody.self, from: ctx.request.bodyData), !body.path.isEmpty else {
                return HTTPResponse.jsonError(status: .badRequest, code: "bad_request", message: "Missing path.")
            }
            do {
                try quota.validateWrite(additionalBytes: 4096, rootURL: vault.rootURL)
                try vault.createDirectory(relativePath: body.path)
                return HTTPResponse.json(status: .created, body: ["created": body.path])
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch {
                return mapVaultError(error)
            }
        }

        await router.register(.GET, "/api/v1/files/*path") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let rel = ctx.param("path") ?? ""
            do {
                let resolved = try vault.resolveSafePath(rel)
                return try vault.streamFileResponse(at: resolved, requestHeaders: ctx.request.headers)
            } catch {
                return mapVaultError(error)
            }
        }

        await router.register(.PUT, "/api/v1/files/*path") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let rel = ctx.param("path") ?? ""
            guard !rel.isEmpty else {
                return HTTPResponse.jsonError(status: .badRequest, code: "bad_request", message: "Missing file path.")
            }
            let incomingSize: UInt64
            switch ctx.request.body {
            case .data(let data):
                incomingSize = UInt64(data.count)
            case .tempFile(_, let size):
                incomingSize = size
            }
            do {
                try quota.validateWrite(additionalBytes: incomingSize, rootURL: vault.rootURL)
                let item: VaultItem
                switch ctx.request.body {
                case .data(let data):
                    item = try vault.writeFile(relativePath: rel, data: data)
                case .tempFile(let url, _):
                    item = try vault.moveUploadedTempFile(url, toRelativePath: rel)
                }
                return HTTPResponse.json(status: .created, body: item)
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch {
                return mapVaultError(error)
            }
        }

        await router.register(.DELETE, "/api/v1/files/*path") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let rel = ctx.param("path") ?? ""
            do {
                try vault.deleteItem(relativePath: rel)
                return HTTPResponse.json(status: .ok, body: ["deleted": rel])
            } catch {
                return mapVaultError(error)
            }
        }

        // MARK: - Collections API
        await router.register(.GET, "/api/v1/collections") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let cols = (try? await store.listCollections()) ?? []
            return HTTPResponse.json(status: .ok, body: ["collections": cols])
        }

        await router.register(.GET, "/api/v1/collections/:name") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let name = ctx.param("name") ?? "default"
            let limit = Int(ctx.request.queryValue("limit") ?? "") ?? 50
            let offset = Int(ctx.request.queryValue("offset") ?? "") ?? 0
            do {
                let docs = try await store.listDocuments(collection: name, limit: limit, offset: offset)
                return HTTPResponse.json(status: .ok, body: docs)
            } catch {
                return HTTPResponse.jsonError(status: .internalServerError, code: "db_error", message: "\(error)")
            }
        }

        await router.register(.POST, "/api/v1/collections/:name") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let name = ctx.param("name") ?? "default"
            let raw = String(data: ctx.request.bodyData, encoding: .utf8) ?? ""
            do {
                try quota.validateWrite(additionalBytes: UInt64(ctx.request.bodyData.count), rootURL: vault.rootURL)
                let doc = try await store.createDocument(collection: name, jsonString: raw)
                return HTTPResponse.json(status: .created, body: doc)
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch RackStoreError.invalidJSON {
                return HTTPResponse.jsonError(status: .badRequest, code: "invalid_json", message: "Request body must be valid JSON.")
            } catch {
                return HTTPResponse.jsonError(status: .internalServerError, code: "db_error", message: "\(error)")
            }
        }

        await router.register(.GET, "/api/v1/collections/:name/:id") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let name = ctx.param("name") ?? "default"
            let id = ctx.param("id") ?? ""
            guard let doc = try? await store.getDocument(collection: name, id: id) else {
                return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "Document not found.")
            }
            return HTTPResponse.json(status: .ok, body: doc)
        }

        await router.register(.PUT, "/api/v1/collections/:name/:id") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let name = ctx.param("name") ?? "default"
            let id = ctx.param("id") ?? ""
            let raw = String(data: ctx.request.bodyData, encoding: .utf8) ?? ""
            do {
                try quota.validateWrite(additionalBytes: UInt64(ctx.request.bodyData.count), rootURL: vault.rootURL)
                let doc = try await store.upsertDocument(collection: name, id: id, jsonString: raw)
                return HTTPResponse.json(status: .ok, body: doc)
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch RackStoreError.invalidJSON {
                return HTTPResponse.jsonError(status: .badRequest, code: "invalid_json", message: "Request body must be valid JSON.")
            } catch {
                return HTTPResponse.jsonError(status: .internalServerError, code: "db_error", message: "\(error)")
            }
        }

        await router.register(.DELETE, "/api/v1/collections/:name/:id") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let name = ctx.param("name") ?? "default"
            let id = ctx.param("id") ?? ""
            let deleted = (try? await store.deleteDocument(collection: name, id: id)) ?? false
            guard deleted else {
                return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "Document not found.")
            }
            return HTTPResponse.json(status: .ok, body: ["deleted": id])
        }

        // MARK: - KV API
        await router.register(.GET, "/api/v1/kv") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let keys = (try? await store.listKeys()) ?? []
            return HTTPResponse.json(status: .ok, body: keys)
        }

        await router.register(.GET, "/api/v1/kv/:key") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let key = ctx.param("key") ?? ""
            guard let entry = try? await store.getValue(key: key) else {
                return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "Key not found or expired.")
            }
            return HTTPResponse.json(status: .ok, body: entry)
        }

        await router.register(.PUT, "/api/v1/kv/:key") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let key = ctx.param("key") ?? ""
            struct KVPayload: Decodable { let value: String; let ttlSeconds: Int? }
            guard let payload = try? JSONDecoder().decode(KVPayload.self, from: ctx.request.bodyData) else {
                return HTTPResponse.jsonError(status: .badRequest, code: "invalid_json", message: "Expected {value, ttlSeconds?}.")
            }
            do {
                try quota.validateWrite(additionalBytes: UInt64(ctx.request.bodyData.count), rootURL: vault.rootURL)
                try await store.setValue(key: key, value: payload.value, ttlSeconds: payload.ttlSeconds)
                struct KVStoredResponse: Encodable { let key: String; let stored: Bool }
                return HTTPResponse.json(status: .ok, body: KVStoredResponse(key: key, stored: true))
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch {
                return HTTPResponse.jsonError(status: .internalServerError, code: "db_error", message: "\(error)")
            }
        }

        await router.register(.DELETE, "/api/v1/kv/:key") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let key = ctx.param("key") ?? ""
            let deleted = (try? await store.deleteValue(key: key)) ?? false
            guard deleted else {
                return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "Key not found.")
            }
            return HTTPResponse.json(status: .ok, body: ["deleted": key])
        }

        // MARK: - Webhooks & Admin Logs
        let webhookHandler: RouteHandler = { ctx in
            if requireAuthForWebhooks && !auth.isAuthorized(ctx.request) {
                return unauthorized()
            }
            let hook = ctx.param("hook") ?? "default"
            let bodyStr = String(data: ctx.request.bodyData, encoding: .utf8) ?? "<binary \(ctx.request.bodyData.count) bytes>"
            let query = ctx.request.target.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init) ?? ""
            do {
                try quota.validateWrite(additionalBytes: UInt64(ctx.request.bodyData.count), rootURL: vault.rootURL)
                let delivery = try await store.recordWebhook(
                    hook: hook,
                    method: ctx.request.method.rawValue,
                    headers: ctx.request.headers.asDictionary,
                    query: query,
                    body: bodyStr,
                    remoteAddress: ctx.request.remoteAddress
                )
                return HTTPResponse.json(status: .created, body: delivery)
            } catch let err as StorageQuotaError {
                return mapQuotaError(err)
            } catch {
                return HTTPResponse.jsonError(status: .internalServerError, code: "db_error", message: "\(error)")
            }
        }
        await router.register(.POST, "/api/v1/webhooks/:hook", handler: webhookHandler)
        await router.register(.PUT, "/api/v1/webhooks/:hook", handler: webhookHandler)
        await router.register(.GET, "/api/v1/webhooks/:hook", handler: webhookHandler)

        await router.register(.GET, "/api/v1/admin/webhooks") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let hook = ctx.request.queryValue("hook")
            let limit = Int(ctx.request.queryValue("limit") ?? "") ?? 50
            let list = (try? await store.listWebhooks(hook: hook, limit: limit)) ?? []
            return HTTPResponse.json(status: .ok, body: list)
        }

        await router.register(.DELETE, "/api/v1/admin/webhooks") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            let hook = ctx.request.queryValue("hook")
            try? await store.clearWebhooks(hook: hook)
            return HTTPResponse.json(status: .ok, body: ["cleared": true])
        }

        await router.register(.GET, "/api/v1/admin/logs") { ctx in
            guard auth.isAuthorized(ctx.request) else { return unauthorized() }
            if let logsHandler {
                return await logsHandler()
            }
            return HTTPResponse.json(status: .ok, body: [String]())
        }

        // MARK: - Static Site Hosting (/)
        let staticHandler: RouteHandler = { ctx in
            if !publicStaticReads && !auth.isAuthorized(ctx.request) {
                return unauthorized()
            }
            let rel = ctx.param("path") ?? ""
            do {
                var response = try vault.serveStatic(path: rel, requestHeaders: ctx.request.headers)
                if ctx.request.method == .HEAD {
                    response.suppressBody = true
                }
                return response
            } catch {
                return mapVaultError(error)
            }
        }
        await router.register(.GET, "/", handler: staticHandler)
        await router.register(.HEAD, "/", handler: staticHandler)
        await router.register(.GET, "/*path", handler: staticHandler)
        await router.register(.HEAD, "/*path", handler: staticHandler)
    }

    private static func unauthorized() -> HTTPResponse {
        var res = HTTPResponse.jsonError(status: .unauthorized, code: "unauthorized", message: "Valid Bearer token or session cookie required.")
        res.headers["WWW-Authenticate"] = "Bearer realm=\"PocketRack\""
        return res
    }

    private static func mapQuotaError(_ err: StorageQuotaError) -> HTTPResponse {
        switch err {
        case .quotaExceeded:
            return HTTPResponse.jsonError(status: .insufficientStorage, code: "quota_exceeded", message: "PocketRack storage quota reached.")
        case .freeSpaceFloorReached:
            return HTTPResponse.jsonError(status: .insufficientStorage, code: "free_space_floor", message: "iPadOS free-space safety floor reached.")
        }
    }

    private static func mapVaultError(_ err: Error) -> HTTPResponse {
        switch err {
        case StorageVaultError.pathTraversal:
            return HTTPResponse.jsonError(status: .forbidden, code: "path_forbidden", message: "Path escapes storage vault.")
        case StorageVaultError.notFound, StorageVaultError.isDirectory:
            return HTTPResponse.jsonError(status: .notFound, code: "not_found", message: "Requested resource was not found.")
        case StorageVaultError.rangeNotSatisfiable:
            return HTTPResponse.jsonError(status: .rangeNotSatisfiable, code: "range_not_satisfiable", message: "Requested byte range is invalid.")
        default:
            return HTTPResponse.jsonError(status: .internalServerError, code: "storage_error", message: "\(err)")
        }
    }
}
