import SwiftUI
import NMCore

public struct ReferenceLookupView: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case oui, port
        public var id: String { rawValue }
        var title: String { self == .oui ? "OUI Lookup" : "Port Lookup" }
    }

    @Environment(\.palette) private var palette
    @NMStateCompat private var kind: Kind
    @NMStateCompat private var query = ""

    public init(kind: Kind = .oui) { _kind = NMStateCompat(wrappedValue: kind) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t(kind.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Lookup"), selection: $kind) { ForEach(Kind.allCases) { Text(t($0.title)).tag($0) } }.pickerStyle(.menu)
            }
            TextField(kind == .oui ? t("MAC address or OUI prefix") : t("Port number or service name"), text: $query)
                .textFieldStyle(.roundedBorder)
            if kind == .oui {
                let vendor = DataStore.shared.vendor(forMACAddress: query)
                Text(vendor ?? (query.isEmpty ? t("Enter a MAC address") : t("No results")))
                    .font(.title3).foregroundStyle(vendor == nil ? palette.textSecondary : palette.textPrimary)
                Text(tf("Loaded %d OUI entries", DataStore.shared.ouiEntryCount)).font(.caption).foregroundStyle(palette.textSecondary)
            } else {
                Table(DataStore.shared.searchPorts(query)) {
                    TableColumn(t("Port")) { Text(String($0.number)) }
                    TableColumn(t("Protocol")) { Text($0.proto.uppercased()) }
                    TableColumn(t("Name")) { Text($0.name) }
                    TableColumn(t("Description")) { Text($0.description).foregroundStyle(palette.textSecondary) }
                }.frame(minHeight: 360)
            }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
    }
}
