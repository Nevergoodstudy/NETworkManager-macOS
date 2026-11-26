import Foundation
import Combine
import NMCore

struct SSHSessionTab: Codable, Identifiable, Equatable {
    var id = UUID()
    let host: String
    let port: Int
    let username: String
    let jumpHost: String
    let credentialID: UUID?

    func displayTarget(configuration: SSHLaunchConfiguration? = nil) -> String {
        let endpoint = username.isEmpty ? host : "\(username)@\(host)"
        let target = "\(configuration?.displayTarget ?? endpoint) (\(t("Port")) \(port))"
        return jumpHost.isEmpty ? target : tf("%@ via %@", target, jumpHost)
    }
}

struct SSHSessionLayout: Codable, Equatable {
    var tabs: [SSHSessionTab] = []
    var selectedID: UUID?
}

@MainActor
final class SSHSessionLayoutStore: ObservableObject {
    static let shared = SSHSessionLayoutStore(
        storageURL: SettingsStore.supportDirectory.appendingPathComponent("ssh-session-layout.json")
    )

    @Published private(set) var layout = SSHSessionLayout()
    @Published private(set) var persistenceError: String?
    private let storageURL: URL

    init(storageURL: URL) {
        self.storageURL = storageURL
        guard let data = try? Data(contentsOf: storageURL),
              var saved = try? JSONDecoder().decode(SSHSessionLayout.self, from: data),
              Set(saved.tabs.map(\.id)).count == saved.tabs.count else { return }
        if !saved.tabs.contains(where: { $0.id == saved.selectedID }) {
            saved.selectedID = saved.tabs.last?.id
        }
        layout = saved
    }

    func save(_ layout: SSHSessionLayout) {
        self.layout = layout
        do {
            try JSONEncoder().encode(layout).write(to: storageURL, options: .atomic)
            persistenceError = nil
        } catch {
            persistenceError = tf("SSH tab layout could not be saved. (%@)", error.localizedDescription)
        }
    }
}
