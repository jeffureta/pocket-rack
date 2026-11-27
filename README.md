# PocketRack

**\$0, zero-dependency, hardware-calibrated Swift/SwiftUI personal server for iPadOS 17+ (tuned for iPad Air M2 — 512 GB / 8 GB RAM / iPadOS 27).**

- **🛡️ Zero-Risk Local Free**: 100% local execution via Apple `Network.framework`, `CryptoKit`, system `SQLite3`, and `SwiftUI`. Zero third-party packages, zero cloud billing, zero paid Apple entitlements.
- **🌐 Static Site Hosting (`/`)**: `ETag`/`304`, HTTP `Range`/`206` streaming, MIME detection, iPad Files (`Documents/`) and USB-C SSD support.
- **🗄️ Backend-in-a-Box (`/api/v1/*`)**: M2-tuned SQLite3 WAL JSON Collections, TTL KV Store, 2,000-event Webhook Inbox, and streaming File API.
- **🖥️ Offline Remote Console (`/_admin`)**: Password/token-gated Web File Manager, Collections/KV Explorer, Webhook Inspector & Live Capacity Gauges.
- **⚡ M2 Capacity Governor & Safety**: Thermal-adaptive socket scaling (`64 → 32 → 16 → 4`), pre-Jetsam `503` backpressure, and `100 GB` quota + `15 GB` iPadOS free-space safety floor (`507`).

## Quickstart (macOS Verification)

```bash
swift test
swift run pocketrack-cli --port 8080
```

See [docs/ipad-deployment-guide.md](docs/ipad-deployment-guide.md) for **\$0** Free Personal Team iPad deployment and 1-command wireless refresh (`./scripts/deploy-ipad.sh`).
