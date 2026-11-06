import Foundation

/// macOS equivalent of the Windows `--application:` startup selector.
/// Unknown arguments are ignored so Finder launches and future options remain
/// compatible with the SwiftUI app entry point.
public struct LaunchOptions: Sendable {
    public let tool: String?
    public let showHelp: Bool
    public let resetSettings: Bool

    public static let current = LaunchOptions(arguments: CommandLine.arguments)

    public init(arguments: [String]) {
        var selected: String?
        var help = false
        var reset = false
        for argument in arguments.dropFirst() {
            if argument == "--help" || argument == "-h" { help = true; continue }
            if argument == "--reset-settings" { reset = true; continue }
            if let value = argument.split(separator: ":", maxSplits: 1).dropFirst().first {
                let key = argument.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased()
                if key == "--application" { selected = Self.map(String(value)) }
            }
            if argument.hasPrefix("--application=") {
                selected = Self.map(String(argument.dropFirst("--application=".count)))
            }
        }
        tool = selected; showHelp = help; resetSettings = reset
    }

    private static func map(_ value: String) -> String? {
        switch value.lowercased() {
        case "dashboard": return "dashboard"
        case "networkinterface": return "network"
        case "wifi": return "wifi"
        case "ipscanner": return "ipScanner"
        case "portscanner": return "portScanner"
        case "pingmonitor": return "ping"
        case "traceroute": return "traceroute"
        case "dnslookup": return "dns"
        case "remotedesktop": return "remote"
        case "powershell": return "powershell"
        case "putty": return "remote"
        case "tigervnc": return "remote"
        case "webconsole": return "web"
        case "snmp": return "snmp"
        case "sntplookup": return "sntp"
        case "discoveryprotocol": return "discovery"
        case "wakeonlan": return "wol"
        case "whois": return "whois"
        case "ipgeolocation": return "geolocation"
        case "subnetcalculator": return "subnet"
        case "bitcalculator": return "bit"
        case "lookup": return "portLookup"
        case "connections": return "connections"
        case "listeners": return "listeners"
        case "arptable", "neighbortable": return "neighbors"
        default: return nil
        }
    }
}

