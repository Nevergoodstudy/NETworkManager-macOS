import Foundation

/// A remote primary key belongs to one source instance and one object type.
/// Addresses, display names and site labels can change without changing this identity.
public struct ExternalAssetIdentity: Codable, Hashable, Sendable {
    public let instance: String
    public let objectType: String
    public let remoteID: String

    public init(instance: String, objectType: String, remoteID: String) {
        let instance = instance.trimmingCharacters(in: .whitespacesAndNewlines)
        var components = URLComponents(string: instance)
        if let scheme = components?.scheme, let host = components?.host {
            components?.scheme = scheme.lowercased()
            components?.host = host.lowercased()
            if (scheme.lowercased() == "https" && components?.port == 443) ||
                (scheme.lowercased() == "http" && components?.port == 80) {
                components?.port = nil
            }
            components?.user = nil
            components?.password = nil
            components?.query = nil
            components?.fragment = nil
            self.instance = (components?.string ?? instance).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            self.instance = instance.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        self.objectType = objectType.trimmingCharacters(in: .whitespacesAndNewlines)
        self.remoteID = remoteID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey { case instance, objectType, remoteID }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(instance: try values.decode(String.self, forKey: .instance),
                  objectType: try values.decode(String.self, forKey: .objectType),
                  remoteID: try values.decode(String.self, forKey: .remoteID))
        guard isValid else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Invalid external asset identity"))
        }
    }

    public var isValid: Bool {
        !instance.isEmpty && instance.utf8.count <= 2_048 &&
            !objectType.isEmpty && objectType.utf8.count <= 200 &&
            !remoteID.isEmpty && remoteID.utf8.count <= 200
    }
}
