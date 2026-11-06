import SwiftUI
import NMCore

public struct NetworkInfoView: View {
    @Environment(\.palette) private var palette
    @NMStateCompat private var interfaces: [NetworkInterfaceInfo] = []
    @NMStateCompat private var includeLoopback = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t("Network Interface")).font(.largeTitle.bold())
                Spacer()
                Toggle(t("Include loopback"), isOn: $includeLoopback)
                    .toggleStyle(.checkbox)
                Button(t("Refresh")) { reload() }.buttonStyle(.bordered)
            }
            Table(interfaces) {
                TableColumn(t("Interface")) { Text($0.name).font(.body.monospaced()) }
                TableColumn(t("Family")) { Text($0.family) }
                TableColumn(t("Address")) { Text($0.address).font(.body.monospaced()) }
                TableColumn(t("Netmask")) { Text($0.netmask).font(.body.monospaced()) }
                TableColumn(t("Status")) { Text($0.isUp ? t("Up") : t("Down")) }
            }
            .frame(minHeight: 380)
            Text(tf("%d address(es)", interfaces.count)).font(.caption).foregroundStyle(palette.textSecondary)
        }
        .padding(28)
        .background(palette.background)
        .task { reload() }
        .onChange(of: includeLoopback) { _, _ in reload() }
    }

    private func reload() { interfaces = NetworkInterfaces.list(includeLoopback: includeLoopback) }
}
