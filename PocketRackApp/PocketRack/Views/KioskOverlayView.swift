import SwiftUI

struct KioskOverlayView: View {
    @Bindable var controller: ServerController
    @State private var now = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 14) {
                Text(now, style: .time)
                    .font(.system(size: 56, weight: .ultraLight, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.28))

                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green.opacity(0.45))
                        .frame(width: 8, height: 8)
                    Text("\(controller.primaryURLString) • \(controller.activeConnections)/\(controller.effectiveConnectionLimit) sockets")
                        .font(.footnote.monospaced())
                        .foregroundStyle(Color.white.opacity(0.28))
                }

                Text("Hold anywhere for 1.5s to wake dashboard")
                    .font(.caption2)
                    .foregroundStyle(Color.white.opacity(0.18))
                    .padding(.top, 16)
            }
        }
        .statusBarHidden(true)
        .onReceive(timer) { now = $0 }
        .onLongPressGesture(minimumDuration: 1.5) {
            controller.isKioskDimmed = false
        }
    }
}
