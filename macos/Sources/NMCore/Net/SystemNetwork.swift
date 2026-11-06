import Foundation

// MARK: - Local socket inventory

/// A normalized socket row used by the Connections and Listeners tools.
///
/// macOS does not expose the Windows IP Helper tables used by the original
/// application. `lsof` is the supported system inventory on macOS; keeping the
/// parser here makes the UI independent from the command's column formatting.
public struct SocketEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let command: String
    public let pid: Int
    public let user: String
    public let fileDescriptor: String
    public let family: String
    public let transport: String
    public let localAddress: String
    public let remoteAddress: String
    public let state: String

    public init(id: String = UUID().uuidString, command: String, pid: Int, user: String,
                fileDescriptor: String, family: String, transport: String,
                localAddress: String, remoteAddress: String, state: String) {
        self.id = id
        self.command = command
        self.pid = pid
        self.user = user
        self.fileDescriptor = fileDescriptor
        self.family = family
        self.transport = transport
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
        self.state = state
    }
}

public enum SocketInventory {
    /// Return all IPv4/IPv6 sockets known by `lsof`.
    public static func list(includeUDP: Bool = true) -> [SocketEntry] {
        let result = Shell.runSync("/usr/sbin/lsof", ["-n", "-P", "-i"])
        guard result.succeeded else { return [] }
        return parse(result.stdout)
            .filter { includeUDP || $0.transport.uppercased() != "UDP" }
    }

    public static func listeners() -> [SocketEntry] {
        list().filter { $0.state.uppercased() == "LISTEN" || $0.state.uppercased() == "LISTENING" }
    }

    public static func connections() -> [SocketEntry] {
        list().filter { $0.state.uppercased() != "LISTEN" && $0.state.uppercased() != "LISTENING" }
    }

    /// Parse the stable, whitespace separated parts of lsof's default output.
    /// The NAME column may contain spaces only in unusual process names, so the
    /// first five columns and the last column are enough for the normal output.
    public static func parse(_ text: String) -> [SocketEntry] {
        var rows: [SocketEntry] = []
        for line in text.split(whereSeparator: { $0.isNewline }).map(String.init) {
            if line.hasPrefix("COMMAND ") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard columns.count >= 9,
                  let pid = Int(columns[1]) else { continue }

            let type = columns[4]
            guard type == "IPv4" || type == "IPv6" else { continue }
            let name = columns[8...].joined(separator: " ")
            let parsed = parseName(name)
            rows.append(SocketEntry(
                command: columns[0], pid: pid, user: columns[2],
                fileDescriptor: columns[3], family: type,
                transport: columns[7], localAddress: parsed.local,
                remoteAddress: parsed.remote, state: parsed.state
            ))
        }
        return rows
    }

    private static func parseName(_ name: String) -> (local: String, remote: String, state: String) {
        let state: String
        if let open = name.lastIndex(of: "("), name.last == ")" {
            state = String(name[name.index(after: open)..<name.index(before: name.endIndex)])
        } else {
            state = ""
        }
        let endpoint = name.split(separator: " ", maxSplits: 1).first.map(String.init) ?? name
        if let arrow = endpoint.range(of: "->") {
            return (String(endpoint[..<arrow.lowerBound]), String(endpoint[arrow.upperBound...]), state)
        }
        return (endpoint, "", state)
    }
}

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

