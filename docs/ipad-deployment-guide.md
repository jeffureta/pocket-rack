# PocketRack — \$0 iPad Air M2 Deployment Guide

## 1. First-Time Install (\$0 Free Apple ID Personal Team)

1. Open `PocketRackApp/PocketRack.xcodeproj` in Xcode on your Mac.
2. Select the **PocketRack** target → **Signing & Capabilities**.
3. Under **Team**, choose your free **Personal Team** (signed into Xcode with your regular Apple ID — **\$0**). If Xcode says the bundle identifier `com.jeffureta.PocketRack` is taken, change it to `com.<yourname>.PocketRack`.
4. Connect your **iPad Air M2** via USB-C and click **Run (`⌘R`)**.
5. On your iPad:
   - Trust your developer certificate under **Settings → General → VPN & Device Management** (if prompted).
   - Tap **Allow** on the **Local Network** permission dialog on first launch.

## 2. 7-Day Free Personal Team Refresh (1-Command Wireless Script)

Free Personal Team provisioning profiles expire every **7 days** (re-signing preserves all files, SQLite databases, and Keychain tokens intact). Once your iPad is paired with Xcode over Wi-Fi, refresh in ~10 seconds without touching Xcode UI:

```bash
./scripts/deploy-ipad.sh
```

## 3. 24/7 Kiosk & Battery Longevity on iPad Air M2

- **80% Charge Limit**: On iPadOS, enable **Settings → Battery → Battery Health → 80% Limit** so keeping the iPad plugged in 24/7 doesn't degrade the battery.
- **Kiosk Dimmer**: Tap **Kiosk Dimmer** on the PocketRack Dashboard to black out the screen while keeping the server active and preventing burn-in. Long-press anywhere for 1.5s to wake.
- **Guided Access** *(Optional)*: Enable **Settings → Accessibility → Guided Access** (`Triple-Click Side Button`) to lock the iPad into PocketRack so accidental touches never background the server.
- **USB-C SSD & Ethernet**: Plug in a USB-C hub with Power Delivery + Gigabit Ethernet + an external SSD, then tap **Mount USB-C Drive or Files Folder** inside **Storage & Sites**.

## 4. Free Remote Access via Tailscale Personal (\$0)

Install the free **Tailscale** app on your iPad and Mac/phone. PocketRack automatically detects your `100.x.y.z` Tailscale IP (`utun*`) and displays it on the Dashboard with a scannable QR code — zero router port forwarding required.
