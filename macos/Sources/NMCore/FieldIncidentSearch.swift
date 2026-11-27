import Foundation

public struct FieldIncidentQuery: Equatable, Sendable {
    public var text: String
    public var status: FieldIncidentStatus?
    public var asset: FieldIncidentAssetReference?
    public var occurredFrom: Date?
    public var occurredThrough: Date?
    public var ticketReference: String?
    public var excludingCaseID: FieldIncidentSearchResult.ID?

    public init(text: String = "", status: FieldIncidentStatus? = nil, asset: FieldIncidentAssetReference? = nil,
                occurredFrom: Date? = nil, occurredThrough: Date? = nil,
                ticketReference: String? = nil, excludingCaseID: FieldIncidentSearchResult.ID? = nil) {
        self.text = text
        self.status = status
        self.asset = asset
        self.occurredFrom = occurredFrom
        self.occurredThrough = occurredThrough
        self.ticketReference = ticketReference
        self.excludingCaseID = excludingCaseID
    }

    public func matches(_ incident: FieldIncident) -> Bool {
        if let ticketReference, Self.ticketKey(ticketReference) != Self.ticketKey(incident.ticketReference) { return false }
        if let status, status != incident.status { return false }
        if let asset {
            guard let candidate = incident.asset else { return false }
            if let identity = asset.externalIdentity {
                guard candidate.externalIdentity == identity else { return false }
            } else if candidate.deviceID != asset.deviceID { return false }
        }
        if occurredFrom != nil || occurredThrough != nil {
            let dates = incident.entries.isEmpty ? [incident.createdAt] : incident.entries.map(\.occurredAt)
            guard dates.contains(where: { date in
                (occurredFrom.map { date >= $0 } ?? true) && (occurredThrough.map { date <= $0 } ?? true)
            }) else { return false }
        }
        let searchable = searchText(for: incident)
        return terms.allSatisfy { searchable.contains($0) }
    }

    // The same deterministic folding is used by session and SQLite searches.
    // SQLite's built-in LIKE only folds ASCII by default.
    var terms: [String] { Self.fold(text).split(whereSeparator: \.isWhitespace).map(String.init) }

    // Encoding preserves literal characters, including NUL, across SQLite text bindings.
    static func ticketKey(_ reference: String) -> String {
        Data(reference.trimmingCharacters(in: .whitespacesAndNewlines)
            .precomposedStringWithCanonicalMapping.utf8).base64EncodedString()
    }

    static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\0", with: " ")
            .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    func searchText(for incident: FieldIncident) -> String {
        let fields = [incident.title, incident.owner, incident.ticketReference, incident.asset?.name ?? "",
                      incident.asset?.address ?? "", incident.asset?.externalIdentity?.remoteID ?? ""] +
            incident.entries.flatMap { [$0.author, $0.detail] }
        return Self.fold(fields.joined(separator: "\n"))
    }

    func validate(limit: Int, offset: Int) throws {
        guard (1...100).contains(limit), offset >= 0 else { throw FieldIncidentSearchError.invalidPage }
        guard text.count <= 2000, terms.count <= 100, asset?.isValid != false,
              ticketReference.map({ $0.count <= 200 && !Self.ticketKey($0).isEmpty }) != false,
              occurredFrom.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false,
              occurredThrough.map({ $0.timeIntervalSinceReferenceDate.isFinite }) != false else {
            throw FieldIncidentSearchError.invalidQuery
        }
        if let from = occurredFrom, let through = occurredThrough, from > through {
            throw FieldIncidentSearchError.invalidQuery
        }
    }
}

public struct FieldIncidentSource: Sendable {
    public let id: String
    public let label: String
    public let loadedAt: Date
    public let project: FieldProject
}

public struct FieldIncidentSearchResult: Identifiable, Sendable {
    public struct ID: Hashable, Sendable {
        public let sourceID: String
        public let incidentID: UUID
    }
    public let source: FieldIncidentSource
    public let incident: FieldIncident
    public var id: ID { ID(sourceID: source.id, incidentID: incident.id) }
    public var latestOccurrence: Date { incident.entries.map(\.occurredAt).max() ?? incident.createdAt }
}

public struct FieldIncidentSearchPage: Sendable {
    public let results: [FieldIncidentSearchResult]
    public let total: Int
}

/// Explicitly loaded project snapshots only. No filesystem scanning, automatic
/// persistence or IP-based device correlation is performed by this catalog.
public struct FieldIncidentCatalog: Sendable {
    public static let maximumSources = 40
    public private(set) var sources: [FieldIncidentSource] = []

    public init() {}

    public mutating func upsert(project: FieldProject, sourceID: String, label: String, loadedAt: Date = Date()) throws {
        guard !sourceID.isEmpty, sourceID.count <= 4096, label.count <= 512,
              loadedAt.timeIntervalSinceReferenceDate.isFinite else { throw FieldIncidentSearchError.invalidSource }
        _ = try project.encoded()
        let source = FieldIncidentSource(id: sourceID, label: label, loadedAt: loadedAt, project: project)
        if let index = sources.firstIndex(where: { $0.id == sourceID }) {
            sources[index] = source
        } else {
            guard sources.count < Self.maximumSources else { throw FieldIncidentSearchError.sourceLimit }
            sources.append(source)
        }
    }

    public func search(_ query: FieldIncidentQuery, limit: Int = 25, offset: Int = 0) throws -> FieldIncidentSearchPage {
        try query.validate(limit: limit, offset: offset)
        let matches = sources.flatMap { source in
            source.project.incidents.filter(query.matches).map { FieldIncidentSearchResult(source: source, incident: $0) }
                .filter { $0.id != query.excludingCaseID }
        }.sorted {
            if $0.latestOccurrence != $1.latestOccurrence { return $0.latestOccurrence > $1.latestOccurrence }
            if $0.source.id != $1.source.id { return $0.source.id < $1.source.id }
            return $0.incident.id.uuidString < $1.incident.id.uuidString
        }
        return FieldIncidentSearchPage(results: Array(matches.dropFirst(min(offset, matches.count)).prefix(limit)), total: matches.count)
    }
}

public enum FieldIncidentSearchError: LocalizedError {
    case sourceLimit, invalidSource, invalidPage, invalidQuery

    public var errorDescription: String? {
        switch self {
        case .sourceLimit: return t("Select up to 40 project files for this search session.")
        case .invalidSource: return t("The project search source is invalid.")
        case .invalidPage: return t("Incident search pages require 1–100 results and a nonnegative offset.")
        case .invalidQuery: return t("Check the search length and occurrence date range.")
        }
    }
}
