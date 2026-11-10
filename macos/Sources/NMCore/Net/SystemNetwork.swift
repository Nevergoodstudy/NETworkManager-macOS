import Foundation

// MARK: - ARP / neighbor table

public struct NeighborEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let address: String
    public let macAddress: String
    public let interface: String
    public let state: String

    public init(id: String = UUID().uuidString, address: String, macAddress: String,
                interface: String, state: String) {
        self.id = id
        self.address = address
        self.macAddress = macAddress
        self.interface = interface
        self.state = state
    }
}

public enum NeighborTable {
    public static func list() -> [NeighborEntry] {
        let result = Shell.runSync("/usr/sbin/arp", ["-an"], timeout: 5)
        guard result.succeeded else { return [] }
        return parse(result.stdout)
    }

    /// Parse output such as `? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0`.
    public static func parse(_ text: String) -> [NeighborEntry] {
        text.split(whereSeparator: { $0.isNewline }).compactMap { raw in
            let line = String(raw)
            guard let left = line.firstIndex(of: "("),
                  let right = line.firstIndex(of: ")"), right > left else { return nil }
            let address = String(line[line.index(after: left)..<right])
            let after = String(line[line.index(after: right)...])
            let tokens = after.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let at = tokens.firstIndex(of: "at"), at + 1 < tokens.count else { return nil }
            let mac = tokens[at + 1]
            let interface = tokens.firstIndex(of: "on").map { $0 + 1 < tokens.count ? tokens[$0 + 1] : "" } ?? ""
            let state = tokens.contains("permanent") ? "Permanent" : (tokens.contains("incomplete") ? "Incomplete" : "Reachable")
            return NeighborEntry(address: address, macAddress: Fmt.mac(mac), interface: interface, state: state)
        }
    }
}

// MARK: - WiFi summary

public struct WiFiSummary: Identifiable, Sendable {
    public var id: String { "\(interface):\(ssid):\(bssid)" }
    public let interface: String
    public let ssid: String
    public let bssid: String
    public let channel: String
    public let security: String
    public let signal: String
    public let raw: String

    public init(interface: String, ssid: String, bssid: String, channel: String,
                security: String, signal: String, raw: String) {
        self.interface = interface
        self.ssid = ssid
        self.bssid = bssid
        self.channel = channel
        self.security = security
        self.signal = signal
        self.raw = raw
    }
}

public enum WiFiInventory {
    public static func current() -> [WiFiSummary] {
        let path = Shell.which("system_profiler") ?? "/usr/sbin/system_profiler"
        let result = Shell.runSync(path, ["SPAirPortDataType", "-detailLevel", "mini"], timeout: 20)
        guard result.succeeded else { return [] }
        return parse(result.stdout)
    }

    /// `system_profiler` is intentionally parsed conservatively. Unknown keys
    /// are retained in raw output so future macOS releases remain useful.
    public static func parse(_ text: String) -> [WiFiSummary] {
        var rows: [WiFiSummary] = []
        var interface = ""
        var ssid = ""
        var bssid = ""
        var channel = ""
        var security = ""
        var signal = ""
        var inCurrentNetwork = false

        func flush() {
            guard !ssid.isEmpty else { return }
            rows.append(WiFiSummary(interface: interface, ssid: ssid, bssid: bssid,
                                    channel: channel, security: security, signal: signal, raw: text))
            ssid = ""; bssid = ""; channel = ""; security = ""; signal = ""
        }

        for raw in text.split(whereSeparator: { $0.isNewline }).map(String.init) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix(":") && !trimmed.contains(" ") && !trimmed.contains("(") {
                let candidate = String(trimmed.dropLast())
                if ["AirPort", "Wi-Fi", "WiFi", "Interfaces"].contains(candidate) { continue }
                if candidate.hasPrefix("en") || candidate.hasPrefix("awdl") || candidate.hasPrefix("llw") || candidate.hasPrefix("p2p") {
                    flush()
                    interface = candidate
                    continue
                }
                if inCurrentNetwork {
                    if !ssid.isEmpty { flush() }
                    ssid = candidate
                    inCurrentNetwork = false
                    continue
                }
                continue
            }
            if trimmed.hasSuffix(":") && trimmed.lowercased().hasPrefix("current network information") {
                inCurrentNetwork = true
                continue
            }
            if inCurrentNetwork && trimmed.hasSuffix(":") && !trimmed.contains("/") {
                let candidate = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
                if !candidate.isEmpty && !candidate.lowercased().contains("network") {
                    if !ssid.isEmpty { flush() }
                    ssid = candidate
                    inCurrentNetwork = false
                    continue
                }
            }
            let parts = trimmed.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "current network information":
                if !ssid.isEmpty { flush() }
                ssid = value
            case "bssid": bssid = value
            case "channel": channel = value
            case "security": security = value
            case "signal / noise": signal = value
            default: continue
            }
        }
        flush()
        return rows
    }
}

