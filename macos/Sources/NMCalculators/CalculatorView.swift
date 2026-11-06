import SwiftUI
import NMCore

public struct CalculatorView: View {
    public enum Kind: String, CaseIterable, Identifiable {
        case subnet, bit
        public var id: String { rawValue }
        var title: String { self == .subnet ? "Subnet Calculator" : "Bit Calculator" }
    }

    @Environment(\.palette) private var palette
    @NMStateCompat private var kind: Kind
    @NMStateCompat private var input = "192.168.1.0/24"
    @NMStateCompat private var bitInput = "1024"

    public init(kind: Kind = .subnet) { _kind = NMStateCompat(wrappedValue: kind) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(t(kind.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Calculator"), selection: $kind) { ForEach(Kind.allCases) { Text(t($0.title)).tag($0) } }.pickerStyle(.menu)
            }
            if kind == .subnet { subnetBody } else { bitBody }
            Spacer()
        }
        .padding(28)
        .background(palette.background)
    }

    private var subnetBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(t("CIDR, for example 192.168.1.0/24"), text: $input).textFieldStyle(.roundedBorder)
            if let subnet = IPv4Subnet(input) {
                resultGrid([
                    (t("Network"), subnet.network.description),
                    (t("Broadcast"), subnet.broadcast.description),
                    (t("Mask"), subnet.maskDescription),
                    (t("Wildcard"), IPv4(raw: subnet.wildcard).description),
                    (t("First host"), subnet.firstHost?.description ?? "—"),
                    (t("Last host"), subnet.lastHost?.description ?? "—"),
                    (t("Usable hosts"), Fmt.integer(subnet.usableHostCount)),
                    (t("Class"), subnet.ipClass)
                ])
                GroupBox(t("Subnets")) {
                    Text(subnet.split(bits: 2).map(\.cidr).joined(separator: "\n"))
                        .font(.body.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else { Text(t("Invalid input")).foregroundStyle(palette.danger) }
        }
    }

    private var bitBody: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(t("Decimal value"), text: $bitInput).textFieldStyle(.roundedBorder)
            if let value = UInt64(bitInput.trimmingCharacters(in: .whitespacesAndNewlines)) {
                resultGrid([
                    (t("Decimal"), String(value)),
                    (t("Hexadecimal"), String(value, radix: 16, uppercase: true)),
                    (t("Binary"), String(value, radix: 2)),
                    (t("Bytes"), Fmt.bytes(Double(value)))
                ])
            } else { Text(t("Invalid input")).foregroundStyle(palette.danger) }
        }
    }

    private func resultGrid(_ rows: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.0).font(.caption).foregroundStyle(palette.textSecondary)
                    Text(row.1).font(.body.monospaced()).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}
