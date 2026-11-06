import SwiftUI
import NMCore

public struct WakeOnLANView: View {
    @Environment(\.palette) private var palette
    @NMStateCompat private var macAddress = ""
    @NMStateCompat private var broadcast = "255.255.255.255"
    @NMStateCompat private var message = ""

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(t("Wake on LAN")).font(.largeTitle.bold())
            Text(t("Send a magic packet to wake a powered-down device on the local network."))
                .foregroundStyle(palette.textSecondary)
            TextField(t("MAC address"), text: $macAddress).textFieldStyle(.roundedBorder)
            TextField(t("Broadcast address"), text: $broadcast).textFieldStyle(.roundedBorder)
            HStack {
                Button(t("Send")) { send() }.buttonStyle(.borderedProminent)
                if !message.isEmpty { Text(message).foregroundStyle(palette.textSecondary) }
            }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
    }

    private func send() {
        switch WakeOnLAN.send(macAddress: macAddress, broadcastAddress: broadcast) {
        case .success: message = t("Magic packet sent")
        case .failure(let error): message = error.localizedDescription
        }
    }
}
