import Foundation

public struct DefaultRouteInfo: Equatable, Sendable {
    public let gateway: String
    public let interface: String

    public init(gateway: String, interface: String) {
        self.gateway = gateway
        self.interface = interface
    }
}

public struct RouteQueryResult: Sendable {
    public let route: DefaultRouteInfo?
    public let error: String?

    public init(route: DefaultRouteInfo?, error: String? = nil) {
        self.route = route
        self.error = error
    }
}

public enum DefaultRouteInventory {
    public static func current() -> RouteQueryResult {
        let result = Shell.runSync("/sbin/route", ["-n", "get", "default"], timeout: 4)
        guard result.succeeded else {
            let message = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            return RouteQueryResult(route: nil, error: message.isEmpty ? t("Unable to read the default route.") : message)
        }
        guard let route = parse(result.stdout) else {
            return RouteQueryResult(route: nil, error: t("macOS returned no default gateway or interface."))
        }
        return RouteQueryResult(route: route)
    }

    public static func parse(_ output: String) -> DefaultRouteInfo? {
        var gateway: String?
        var interface: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }
            switch key {
            case "gateway": gateway = value
            case "interface": interface = value
            default: continue
            }
        }
        guard let gateway, let interface else { return nil }
        return DefaultRouteInfo(gateway: gateway, interface: interface)
    }
}
