import Foundation

// MARK: - Data store

/// Loads the bundled OUI / port / WHOIS reference data.
///
/// The XML files are the very same data sets that ship with the Windows
/// application, so lookups return identical results.
public final class DataStore {
    public static let shared = DataStore()

    private let lock = NSLock()
    private var ouiTable: [String: String]?
    private var portTable: [Int: [(proto: String, name: String, description: String)]]?
    private var whoisTable: [String: String]?

    private var resourceDirectory: URL? {
        // A stdio helper's main bundle can be Contents/Helpers with no
        // executableURL. Locate the enclosing app before Bundle.module, whose
        // generated accessor terminates the process when no bundle is found.
        var directory = Bundle.main.bundleURL
        for _ in 0..<3 {
            if directory.pathExtension.lowercased() == "app" {
                let resourceBundle = directory.appendingPathComponent("Contents/Resources/NETworkManagerMac_NMCore.bundle")
                // Xcode emits a real bundle; native SwiftPM emits a plain
                // directory. Neither needs Bundle initialization to read XML.
                return ["Contents/Resources/Resources", "Resources"]
                    .map { resourceBundle.appendingPathComponent($0) }
                    .first { FileManager.default.fileExists(atPath: $0.path) }
            }
            directory.deleteLastPathComponent()
        }
        #if SWIFT_PACKAGE
        return Bundle.module.resourceURL?.appendingPathComponent("Resources")
        #else
        return Bundle.main.resourceURL?.appendingPathComponent("Resources")
        #endif
    }

    private func resourceURL(_ name: String) -> URL? {
        if let directory = resourceDirectory {
            let candidate = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        // Fallback for the packaged application bundle.
        for bundle in Bundle.allBundles + [Bundle.main] {
            if let url = bundle.url(forResource: name.replacingOccurrences(of: ".xml", with: ""), withExtension: "xml") {
                return url
            }
        }
        return nil
    }

    // MARK: OUI

    public func vendor(forMACAddress mac: String) -> String? {
        let key = String(mac.filter { $0.isHexDigit }.uppercased().prefix(6))
        guard key.count == 6 else { return nil }
        return ouiTableLoaded[key]
    }

    private var ouiTableLoaded: [String: String] {
        lock.lock()
        if let table = ouiTable { lock.unlock(); return table }
        lock.unlock()

        var table: [String: String] = [:]
        if let url = resourceURL("OUI.xml") {
            for values in XMLRelay.parseMany(url: url, itemTag: "OUI", fields: ["MACAddress", "Vendor"]) {
                guard let mac = values["MACAddress"], let vendor = values["Vendor"] else { continue }
                table[String(mac.uppercased().prefix(6))] = vendor
            }
        }
        lock.lock(); ouiTable = table; lock.unlock()
        return table
    }

    // MARK: Ports

    public struct PortInfo: Sendable, Identifiable {
        public var id: String { "\(number)/\(proto)" }
        public let number: Int
        public let proto: String
        public let name: String
        public let description: String
    }

    public func ports(number: Int) -> [(proto: String, name: String, description: String)] {
        portTableLoaded[number] ?? []
    }

    public func portInfo(number: Int) -> [PortInfo] {
        ports(number: number).map { PortInfo(number: number, proto: $0.proto, name: $0.name, description: $0.description) }
    }

    public func searchPorts(_ query: String) -> [PortInfo] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        let table = portTableLoaded
        var results: [PortInfo] = []

        if let number = Int(trimmed) {
            results = (table[number] ?? []).map { PortInfo(number: number, proto: $0.proto, name: $0.name, description: $0.description) }
            return results
        }

        for (number, entries) in table.sorted(by: { $0.key < $1.key }) {
            for entry in entries where entry.name.lowercased().contains(trimmed)
                || entry.description.lowercased().contains(trimmed) {
                results.append(PortInfo(number: number, proto: entry.proto, name: entry.name, description: entry.description))
                if results.count > 500 { return results }
            }
        }
        return results
    }

    public var allPorts: [PortInfo] {
        portTableLoaded.sorted { $0.key < $1.key }.flatMap { number, entries in
            entries.map { PortInfo(number: number, proto: $0.proto, name: $0.name, description: $0.description) }
        }
    }

    private var portTableLoaded: [Int: [(proto: String, name: String, description: String)]] {
        lock.lock()
        if let table = portTable { lock.unlock(); return table }
        lock.unlock()

        var table: [Int: [(proto: String, name: String, description: String)]] = [:]
        if let url = resourceURL("Ports.xml") {
            let entries = XMLRelay.parseMany(url: url, itemTag: "Port", fields: ["Number", "Protocol", "Name", "Description"])
            for values in entries {
                guard let numberText = values["Number"], let number = Int(numberText) else { continue }
                let proto = values["Protocol"] ?? "tcp"
                let name = values["Name"] ?? ""
                let description = values["Description"] ?? ""
                table[number, default: []].append((proto, name, description))
            }
        }
        lock.lock(); portTable = table; lock.unlock()
        return table
    }

    // MARK: WHOIS servers

    public func whoisServer(for query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let table = whoisTableLoaded
        let parts = trimmed.split(separator: ".")
        if parts.count >= 2, let tld = parts.last.map(String.init) {
            if let server = table[tld.uppercased()] { return server }
        }
        if let server = table[trimmed.uppercased()] { return server }
        return "whois.iana.org"
    }

    private var whoisTableLoaded: [String: String] {
        lock.lock()
        if let table = whoisTable { lock.unlock(); return table }
        lock.unlock()

        var table: [String: String] = [:]
        if let url = resourceURL("WhoisServers.xml") {
            for values in XMLRelay.parseMany(url: url, itemTag: "WhoisServer", fields: ["TLD", "Server"]) {
                guard let tld = values["TLD"], let server = values["Server"] else { continue }
                table[tld.uppercased()] = server
            }
        }
        lock.lock(); whoisTable = table; lock.unlock()
        return table
    }

    // MARK: Stats

    public var ouiEntryCount: Int { ouiTableLoaded.count }
    public var portEntryCount: Int { portTableLoaded.count }
    public var whoisServerCount: Int { whoisTableLoaded.count }
}

// MARK: - Lightweight XML helper

/// Streaming XML reader specialised for the flat `<Item><Field>value</Field>...</Item>`
/// structure of the bundled data files.
enum XMLRelay {
    final class Delegate: NSObject, XMLParserDelegate {
        let itemTag: String
        let fields: Set<String>
        var items: [[String: String]] = []

        private var currentItem: [String: String]?
        private var currentElement: String = ""
        private var currentText = ""

        init(itemTag: String, fields: [String]) {
            self.itemTag = itemTag
            self.fields = Set(fields)
        }

        func parser(_ parser: XMLParser, didStartElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            currentElement = elementName
            currentText = ""
            if elementName == itemTag { currentItem = [:] }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            currentText += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String,
                    namespaceURI: String?, qualifiedName qName: String?) {
            if elementName == itemTag {
                if let item = currentItem { items.append(item) }
                currentItem = nil
                return
            }
            if fields.contains(elementName), currentItem != nil {
                currentItem?[elementName] = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    static func parseMany(url: URL, itemTag: String, fields: [String]) -> [[String: String]] {
        guard let parser = XMLParser(contentsOf: url) else { return [] }
        let delegate = Delegate(itemTag: itemTag, fields: fields)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        return delegate.items
    }

    static func parse<T>(url: URL, itemTag: String, fields: [String],
                         transform: ([String: String]) -> T?) -> [String: T] {
        var result: [String: T] = [:]
        for item in parseMany(url: url, itemTag: itemTag, fields: fields) {
            if let value = transform(item) as? (key: String, value: T) {
                result[value.key] = value.value
            }
        }
        return result
    }
}
