import Foundation
import Network

public struct RackConfiguration: Sendable {
    public var port: UInt16
    public var bonjourName: String?
    public var rootURL: URL
    public var databasePath: String
    public var authToken: String
    public var profile: CapacityProfile
    public var publicStaticReads: Bool
    public var requireAuthForWebhooks: Bool

    public init(
        port: UInt16 = 8080,
        bonjourName: String? = "PocketRack",
        rootURL: URL,
        databasePath: String,
        authToken: String,
        profile: CapacityProfile = .balancedM2,
        publicStaticReads: Bool = true,
        requireAuthForWebhooks: Bool = false
    ) {
        self.port = port
        self.bonjourName = bonjourName
        self.rootURL = rootURL
        self.databasePath = databasePath
        self.authToken = authToken
        self.profile = profile
        self.publicStaticReads = publicStaticReads
        self.requireAuthForWebhooks = requireAuthForWebhooks
    }
}

public actor RackServer {
    private let port: UInt16
    private let bonjourName: String?
    private let router: RackRouter
    private let governor: CapacityGovernor
    private let ledger: RequestLedger
    private let queue = DispatchQueue(label: "com.pocketrack.nwlistener", qos: .userInitiated)
    private var listener: NWListener?
    private var startedAt: Date?

    public init(
        port: UInt16,
        bonjourName: String?,
        router: RackRouter,
        governor: CapacityGovernor,
        ledger: RequestLedger
    ) {
        self.port = port
        self.bonjourName = bonjourName
        self.router = router
        self.governor = governor
        self.ledger = ledger
    }

    public func start() async throws -> UInt16 {
        if let listener, let bound = listener.port?.rawValue {
            return bound
        }
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        let newListener = try NWListener(using: params, on: nwPort)
        if let bonjourName, !bonjourName.isEmpty {
            newListener.service = NWListener.Service(name: bonjourName, type: "_http._tcp")
        }

        let boundPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedFlag()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if resumed.trySet(), let actualPort = newListener.port?.rawValue {
                        continuation.resume(returning: actualPort)
                    }
                case .failed(let error):
                    if resumed.trySet() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [router, governor, ledger] connection in
                Task {
                    await Self.handleConnection(connection, router: router, governor: governor, ledger: ledger)
                }
            }
            newListener.start(queue: queue)
        }

        self.listener = newListener
        self.startedAt = Date()
        return boundPort
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        startedAt = nil
    }

    public func uptimeSeconds() -> TimeInterval {
        guard let startedAt else { return 0 }
        return Date().timeIntervalSince(startedAt)
    }

    private static func handleConnection(
        _ connection: NWConnection,
        router: RackRouter,
        governor: CapacityGovernor,
        ledger: RequestLedger
    ) async {
        let admission = await governor.acquireSlot()
        guard admission == .admitted else {
            connection.start(queue: DispatchQueue.global(qos: .utility))
            var resp = HTTPResponse.jsonError(status: .serviceUnavailable, code: "server_busy", message: "PocketRack capacity limit reached. Retry shortly.")
            resp.headers["Retry-After"] = "5"
            let data = HTTPResponseSerializer.serializeHead(for: resp) + resp.body.dataOrEmpty
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
            return
        }

        let startTime = Date()
        let remoteAddr = Self.extractRemoteIP(connection.endpoint)
        let profile = await governor.profile
        let chunkSize = profile.streamChunkSizeBytes
        let maxUpload = profile.maxFileUploadBytes

        connection.start(queue: DispatchQueue.global(qos: .userInitiated))

        do {
            let request = try await receiveHTTPRequest(
                from: connection,
                remoteAddress: remoteAddr,
                maxJSONBodyBytes: profile.maxJSONBodyBytes,
                maxUploadBytes: maxUpload,
                chunkSize: chunkSize
            )
            defer {
                if case .tempFile(let url, _) = request.body {
                    try? FileManager.default.removeItem(at: url)
                }
            }

            let response = try await router.handle(request)
            let bytesOut = try await sendHTTPResponse(response, over: connection)
            let elapsedMs = Date().timeIntervalSince(startTime) * 1000.0
            await ledger.record(RequestLogEntry(
                method: request.method.rawValue,
                path: request.path,
                statusCode: response.status.code,
                durationMs: elapsedMs,
                bytesOut: bytesOut,
                remoteAddress: remoteAddr
            ))
        } catch let codecError as HTTPCodecError {
            let status: HTTPStatus = switch codecError {
            case .headersTooLarge: .headersTooLarge
            case .payloadTooLarge: .payloadTooLarge
            case .malformedRequest, .unsupportedMethod: .badRequest
            }
            let errResp = HTTPResponse.jsonError(status: status, code: "http_error", message: "\(codecError)")
            _ = try? await sendHTTPResponse(errResp, over: connection)
        } catch {
            let errResp = HTTPResponse.jsonError(status: .internalServerError, code: "internal_error", message: "\(error)")
            _ = try? await sendHTTPResponse(errResp, over: connection)
        }

        connection.cancel()
        await governor.releaseSlot()
    }

    private static func receiveHTTPRequest(
        from connection: NWConnection,
        remoteAddress: String,
        maxJSONBodyBytes: Int,
        maxUploadBytes: UInt64,
        chunkSize: Int
    ) async throws -> HTTPRequest {
        var buffer = Data()
        let separator = Data([13, 10, 13, 10])
        let maxHeaders = 64 * 1024

        // Read until header terminator
        while buffer.range(of: separator) == nil {
            if buffer.count > maxHeaders { throw HTTPCodecError.headersTooLarge }
            let chunk = try await receiveChunk(from: connection, maxLength: chunkSize)
            guard !chunk.isEmpty else { throw HTTPCodecError.malformedRequest }
            buffer.append(chunk)
        }

        guard let headerEnd = buffer.range(of: separator) else {
            throw HTTPCodecError.malformedRequest
        }
        if headerEnd.lowerBound > maxHeaders {
            throw HTTPCodecError.headersTooLarge
        }

        let headerBytes = buffer.subdata(in: 0..<headerEnd.lowerBound)
        let leftoverBody = buffer.subdata(in: headerEnd.upperBound..<buffer.count)

        guard let headerText = String(data: headerBytes, encoding: .utf8) else {
            throw HTTPCodecError.malformedRequest
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let reqLine = lines.first else { throw HTTPCodecError.malformedRequest }
        let parts = reqLine.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1."),
              let method = HTTPMethod(rawValue: String(parts[0]).uppercased()) else {
            throw HTTPCodecError.malformedRequest
        }
        let target = String(parts[1])
        var headers = HTTPHeaders()
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { throw HTTPCodecError.malformedRequest }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers.add(k, value: v)
        }

        // Stream large file PUTs directly to a temporary file to maintain constant low RAM on iPadOS
        let pathOnly = String(target.split(separator: "?", maxSplits: 1).first ?? "/")
        let isFilePut = method == .PUT && pathOnly.hasPrefix("/api/v1/files/")
        if isFilePut, let clStr = headers["Content-Length"], let contentLength = UInt64(clStr) {
            if contentLength > maxUploadBytes {
                throw HTTPCodecError.payloadTooLarge
            }
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("pocketrack-upload-\(UUID().uuidString)")
            FileManager.default.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            defer { try? handle.close() }

            var written: UInt64 = 0
            if !leftoverBody.isEmpty {
                let toWrite = min(UInt64(leftoverBody.count), contentLength)
                try handle.write(contentsOf: leftoverBody.prefix(Int(toWrite)))
                written += toWrite
            }
            while written < contentLength {
                let nextChunk = try await receiveChunk(from: connection, maxLength: chunkSize)
                guard !nextChunk.isEmpty else { throw HTTPCodecError.malformedRequest }
                let remaining = contentLength - written
                let slice = UInt64(nextChunk.count) > remaining ? nextChunk.prefix(Int(remaining)) : nextChunk
                try handle.write(contentsOf: slice)
                written += UInt64(slice.count)
            }
            return HTTPRequest(method: method, target: target, headers: headers, body: .tempFile(tempURL, size: written), remoteAddress: remoteAddress)
        }

        // Otherwise use HTTPRequestParser for normal requests / chunked bodies
        var parser = HTTPRequestParser(maxHeaderBytes: maxHeaders, maxBodyBytes: maxJSONBodyBytes)
        var initial = Data(headerBytes)
        initial.append(separator)
        initial.append(leftoverBody)

        switch try parser.feed(initial, remoteAddress: remoteAddress) {
        case .complete(let req, _):
            return req
        case .needMoreData:
            while true {
                let chunk = try await receiveChunk(from: connection, maxLength: chunkSize)
                guard !chunk.isEmpty else { throw HTTPCodecError.malformedRequest }
                if case .complete(let req, _) = try parser.feed(chunk, remoteAddress: remoteAddress) {
                    return req
                }
            }
        }
    }

    private static func receiveChunk(from connection: NWConnection, maxLength: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: maxLength) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    private static func sendHTTPResponse(_ response: HTTPResponse, over connection: NWConnection) async throws -> UInt64 {
        let head = HTTPResponseSerializer.serializeHead(for: response)
        try await sendData(head, over: connection)
        guard !response.suppressBody else { return 0 }

        switch response.body {
        case .data(let data):
            if !data.isEmpty {
                try await sendData(data, over: connection)
            }
            return UInt64(data.count)
        case .fileStream(let url, let offset, let length, let chunkSize):
            guard length > 0 else { return 0 }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: offset)
            var remaining = length
            while remaining > 0 {
                let toRead = Int(min(UInt64(chunkSize), remaining))
                let chunk = handle.readData(ofLength: toRead)
                if chunk.isEmpty { break }
                try await sendData(chunk, over: connection)
                remaining -= UInt64(chunk.count)
            }
            return length
        }
    }

    private static func sendData(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func extractRemoteIP(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "unknown"
        }
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    func trySet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}

public actor RackApplication {
    public let configuration: RackConfiguration
    public let router: RackRouter
    public let auth: AuthGate
    public let vault: StorageVault
    public let quota: StorageQuotaGuard
    public let store: RackStore
    public let governor: CapacityGovernor
    public let ledger: RequestLedger
    public let server: RackServer

    public init(
        configuration: RackConfiguration,
        probe: any SystemResourceProbe = DefaultSystemResourceProbe(),
        diskProbe: any DiskSpaceProbe = DefaultDiskSpaceProbe()
    ) async throws {
        self.configuration = configuration
        self.router = RackRouter()
        self.auth = AuthGate(token: configuration.authToken)
        self.vault = StorageVault(rootURL: configuration.rootURL, streamChunkSize: configuration.profile.streamChunkSizeBytes)
        self.quota = StorageQuotaGuard(
            quotaBytes: configuration.profile.storageQuotaBytes,
            minFreeFloorBytes: configuration.profile.minFreeDiskFloorBytes,
            probe: diskProbe
        )
        self.store = try RackStore(path: configuration.databasePath, profile: configuration.profile)
        self.governor = CapacityGovernor(profile: configuration.profile, probe: probe)
        self.ledger = RequestLedger(maxEntries: 500)
        self.server = RackServer(
            port: configuration.port,
            bonjourName: configuration.bonjourName,
            router: router,
            governor: governor,
            ledger: ledger
        )

        let serverRef = self.server
        let governorRef = self.governor
        let ledgerRef = self.ledger
        let quotaRef = self.quota
        let vaultRef = self.vault

        await router.register(.GET, "/_admin") { _ in
            HTTPResponse.html(AdminConsole.htmlDocument())
        }

        await RackAPIHandlers.registerAll(
            on: router,
            auth: auth,
            vault: vault,
            quota: quota,
            store: store,
            governor: governor,
            publicStaticReads: configuration.publicStaticReads,
            requireAuthForWebhooks: configuration.requireAuthForWebhooks,
            healthHandler: { authorized in
                if !authorized {
                    return HTTPResponse.json(status: .ok, body: ["status": "healthy", "version": PocketRackVersion.current])
                }
                let snap = await governorRef.currentSnapshot()
                let disk = quotaRef.usageSummary(for: vaultRef.rootURL)
                let uptime = await serverRef.uptimeSeconds()
                let totalReqs = await ledgerRef.totalRequests()
                let bytes = await ledgerRef.bytesServed()
                let telemetry = TelemetrySnapshot(
                    uptimeSeconds: uptime,
                    totalRequests: totalReqs,
                    bytesServed: bytes,
                    activeConnections: snap.active,
                    effectiveConnectionLimit: snap.limit,
                    thermalState: snap.thermal,
                    availableMemoryBytes: snap.memoryHeadroomBytes,
                    storageUsedBytes: disk.usedBytes,
                    storageQuotaBytes: disk.quotaBytes,
                    availableVolumeBytes: disk.availableVolumeBytes,
                    minFreeFloorBytes: disk.minFreeFloorBytes,
                    batteryLevel: snap.batteryLevel,
                    batteryCharging: snap.batteryCharging
                )
                return HTTPResponse.json(status: .ok, body: telemetry)
            },
            logsHandler: {
                let logs = await ledgerRef.recent(limit: 100)
                return HTTPResponse.json(status: .ok, body: logs)
            }
        )
    }

    public func start() async throws -> UInt16 {
        try await server.start()
    }

    public func stop() async {
        await server.stop()
    }
}
