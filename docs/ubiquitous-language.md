# PocketRack Ubiquitous Language

All Swift symbols, API endpoints, database tables, and UI labels MUST adhere strictly to this canonical vocabulary:

- **Rack**: A running PocketRack personal server instance hosted on an iPad (or macOS CLI).
- **RackServer**: The `Network.framework` (`NWListener`) TCP + Bonjour (`_http._tcp`) server engine and `RackApplication` façade.
- **RackRouter**: Protocol-based, `Sendable` HTTP router supporting exact paths, `:param` segments, `*wildcard` suffixes, and composable async middleware.
- **CapacityProfile**: Hardware-calibrated resource policy preset (`.eco`, `.balancedM2`, `.performanceM2`) defining socket ceilings, streaming chunk size, JSON/file limits, SQLite pragmas, and disk quotas.
- **CapacityGovernor**: Actor enforcing thermal-adaptive concurrency scaling (`64 -> 32 -> 16 -> 4` sockets) and pre-Jetsam memory backpressure (`503 Retry-After`).
- **StorageQuotaGuard**: Pre-flight storage verifier enforcing the configured PocketRack quota (default `100 GB`) and iPadOS volume free-space floor (default `15 GB`), returning `507 Insufficient Storage` on breach.
- **AuthGate**: Constant-time Bearer/`X-Rack-Token` authenticator and `CryptoKit` `HMAC<SHA256>` stateless `HttpOnly; SameSite=Strict` cookie session manager.
- **StorageVault**: Canonical path-confined file engine (`resolvingSymlinksInPath()`) providing static site serving, `ETag`/`304`, `Range`/`206`/`416`, and atomic chunked streaming uploads.
- **RackStore**: Swift `actor` wrapping system `libsqlite3` (WAL mode, M2-tuned `cache_size` & `mmap_size`) for JSON **Collections**, TTL-aware **KV Store**, and bounded **WebhookDelivery** inbox.
- **WebhookDelivery**: A captured inbound HTTP request stored in `RackStore` with method, path, headers, query, body, timestamp, and remote IP.
- **RequestLedger**: Bounded 500-entry ring buffer + `AsyncStream` broadcaster recording `RequestLogEntry` records for live UI and `/_admin` inspection.
- **TelemetrySnapshot**: Point-in-time hardware & server health snapshot (uptime, sockets vs thermal limit, RAM headroom, disk used/free, battery, thermal state).
- **KioskShield**: Burn-in-safe pitch-black full-screen dimmer overlay on iPadOS requiring a deliberate long-press to wake.
