import Foundation
import NMCore

public struct SSHCommandTemplate: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let command: String

    public static let readOnly: [SSHCommandTemplate] = [
        SSHCommandTemplate(id: "ios-version", title: "Show version", command: "show version"),
        SSHCommandTemplate(id: "ios-interfaces", title: "Interface summary", command: "show ip interface brief"),
        SSHCommandTemplate(id: "ios-interface-status", title: "Interface status", command: "show interfaces status"),
        SSHCommandTemplate(id: "ios-lldp", title: "LLDP neighbors", command: "show lldp neighbors")
    ]

    public init(id: String, title: String, command: String) {
        self.id = id
        self.title = title
        self.command = command
    }
}

public enum SSHCommandDisposition: Equatable, Sendable {
    case readOnly(templateID: String)
    case requiresConfirmation
}

public enum SSHCommandPolicy {
    public enum ValidationError: LocalizedError {
        case empty
        case tooLong
        case controlCharacter

        public var errorDescription: String? {
            switch self {
            case .empty: return t("Enter a command to send.")
            case .tooLong: return t("Commands must be 512 characters or fewer.")
            case .controlCharacter: return t("Commands cannot contain line breaks or control characters.")
            }
        }
    }

    public static func review(_ command: String) throws -> SSHCommandDisposition {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.empty
        }
        guard command.count <= 512 else { throw ValidationError.tooLong }
        guard command.unicodeScalars.allSatisfy({ scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            scalar.properties.generalCategory != .format &&
            scalar.properties.generalCategory != .lineSeparator &&
            scalar.properties.generalCategory != .paragraphSeparator
        }) else {
            throw ValidationError.controlCharacter
        }
        if let template = SSHCommandTemplate.readOnly.first(where: { $0.command == command }) {
            return .readOnly(templateID: template.id)
        }
        return .requiresConfirmation
    }

    /// Keep the review surface unambiguous even if a caller passes text from
    /// an older persisted draft. Format characters are rejected for sending,
    /// while other non-printing scalars are rendered as explicit code points.
    public static func reviewedText(_ command: String) -> String {
        command.unicodeScalars.map { scalar in
            let category = scalar.properties.generalCategory
            let isNonPrinting = CharacterSet.controlCharacters.contains(scalar) ||
                category == .format || category == .lineSeparator || category == .paragraphSeparator
            guard isNonPrinting else { return String(scalar) }
            return String(format: "\\u{%02X}", scalar.value)
        }.joined()
    }
}
