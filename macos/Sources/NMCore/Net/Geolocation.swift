import Foundation

public struct IPGeolocation: Codable, Hashable, Sendable {
    public let ip: String
    public let success: Bool
    public let continent: String?
    public let country: String?
    public let countryCode: String?
    public let region: String?
    public let city: String?
    public let postal: String?
    public let latitude: Double?
    public let longitude: Double?
    public let timezone: String?
    public let isp: String?
    public let organization: String?
    public let asn: String?
    public let error: String?

    public init(ip: String, success: Bool, continent: String? = nil, country: String? = nil,
                countryCode: String? = nil, region: String? = nil, city: String? = nil,
                postal: String? = nil, latitude: Double? = nil, longitude: Double? = nil,
                timezone: String? = nil, isp: String? = nil, organization: String? = nil,
                asn: String? = nil, error: String? = nil) {
        self.ip = ip; self.success = success; self.continent = continent; self.country = country
        self.countryCode = countryCode; self.region = region; self.city = city; self.postal = postal
        self.latitude = latitude; self.longitude = longitude; self.timezone = timezone; self.isp = isp
        self.organization = organization; self.asn = asn; self.error = error
    }

    public var location: String {
        [city, region, country].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public enum IPGeolocationError: LocalizedError {
    case invalidAddress
    case service(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress: return t("Enter a valid IP address or hostname.")
        case .service(let message): return message
        case .network(let message): return message
        }
    }
}

/// Looks up an address using ipwho.is, a JSON HTTPS service with no API key.
/// The request is made only after the user presses Lookup; this preserves the
/// original application's opt-in behaviour and keeps the feature transparent.
public enum IPGeolocationClient {
    private struct Response: Decodable {
        let success: Bool?
        let ip: String?
        let continent: String?
        let country: String?
        let countryCode: String?
        let region: String?
        let city: String?
        let postal: String?
        let latitude: Double?
        let longitude: Double?
        let timezone: Timezone?
        let connection: Connection?
        let error: ErrorPayload?

        struct Timezone: Decodable { let id: String? }
        struct Connection: Decodable { let isp: String?; let org: String?; let asn: Int? }
        struct ErrorPayload: Decodable { let message: String? }
    }

    public static func lookup(_ value: String, timeout: TimeInterval = 10) async throws -> IPGeolocation {
        let input = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, input.count <= 253,
              !input.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !input.contains(where: { "/?#".contains($0) }) else {
            throw IPGeolocationError.invalidAddress
        }
        let escaped = input.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? input
        guard let url = URL(string: "https://ipwho.is/\(escaped)") else { throw IPGeolocationError.invalidAddress }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("NETworkManager-macOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw IPGeolocationError.network(tf("Geolocation service returned HTTP %d.", http.statusCode))
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let success = decoded.success ?? false
            if !success {
                throw IPGeolocationError.service(decoded.error?.message ?? t("The geolocation service could not resolve this address."))
            }
            return IPGeolocation(
                ip: decoded.ip ?? input, success: success, continent: decoded.continent,
                country: decoded.country, countryCode: decoded.countryCode, region: decoded.region,
                city: decoded.city, postal: decoded.postal, latitude: decoded.latitude,
                longitude: decoded.longitude, timezone: decoded.timezone?.id,
                isp: decoded.connection?.isp, organization: decoded.connection?.org,
                asn: decoded.connection?.asn.map { "AS\($0)" }
            )
        } catch let error as IPGeolocationError {
            throw error
        } catch {
            throw IPGeolocationError.network(error.localizedDescription)
        }
    }
}

