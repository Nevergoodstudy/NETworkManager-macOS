import Foundation
import Darwin
import CryptoKit
@testable import NMCore
import NMScanners
import NMCalculators
import NMRemote
import NMIntegrations

struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

final class DiagnosticStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: DiagnosticRunStatus?

    func set(_ status: DiagnosticRunStatus) { lock.lock(); value = status; lock.unlock() }
    func get() -> DiagnosticRunStatus? { lock.lock(); defer { lock.unlock() }; return value }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure(description: message) }
}

func loopbackNTPResponse(for request: Data) -> Data? {
    guard request.count == 48, request[0] & 0x07 == 3,
          request[40..<48].contains(where: { $0 != 0 }) else { return nil }
    var response = Data(repeating: 0, count: 48)
    response[0] = 0x24
    response[1] = 1
    response.replaceSubrange(24..<32, with: request[40..<48])
    response.replaceSubrange(32..<40, with: request[40..<48])
    response.replaceSubrange(40..<48, with: request[40..<48])
    return response
}

private final class AddressResolutionSessionFixture: AddressResolutionSession {
    private var descriptors = [Int32](repeating: -1, count: 2)
    private(set) var didCancel = false

    init() {
        _ = descriptors.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }
    }

    var fileDescriptor: Int32 { descriptors[0] }
    var isFinished: Bool { false }
    var errorCode: Int32? { nil }
    var addresses: [ResolvedSocketAddress] { [] }

    func processPendingResults() -> Int32 { 0 }

    func cancel() {
        guard !didCancel else { return }
        didCancel = true
        for index in descriptors.indices where descriptors[index] >= 0 {
            close(descriptors[index])
            descriptors[index] = -1
        }
    }
}

private final class AddressResolutionStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func markCancelled() {
        lock.lock(); value = true; lock.unlock()
    }
}

private func checkAddressResolutionCancellation() throws {
    let cancellation = DiagnosticCancellation()
    let session = AddressResolutionSessionFixture()
    let result = AddressResolutionStatusBox()
    let finished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        do {
            _ = try SocketAddressResolver.collectAddresses(from: session, timeout: 10, cancellation: cancellation)
        } catch SocketAddressResolutionError.cancelled {
            result.markCancelled()
        } catch {}
        finished.signal()
    }
    usleep(50_000)
    cancellation.cancel()
    guard finished.wait(timeout: .now() + 1) == .success, result.wasCancelled, session.didCancel else {
        throw CheckFailure(description: "Host resolution cancellation should release the DNS request promptly")
    }

    let timeoutSession = AddressResolutionSessionFixture()
    do {
        _ = try SocketAddressResolver.collectAddresses(from: timeoutSession, timeout: 0.05, cancellation: nil)
        throw CheckFailure(description: "An unanswered address resolution should time out")
    } catch SocketAddressResolutionError.timedOut {
        try check(timeoutSession.didCancel, "address resolution timeout releases its request")
    }
}

final class LoopbackTCPListener {
    let fileDescriptor: Int32
    let port: Int

    init() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var shouldClose = true
        defer { if shouldClose { close(descriptor) } }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let bindStatus = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindStatus == 0, listen(descriptor, 4) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameStatus = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard nameStatus == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        fileDescriptor = descriptor
        port = Int(UInt16(bigEndian: address.sin_port))
        shouldClose = false
    }

    deinit { close(fileDescriptor) }
}

final class LoopbackWhoisFixture: @unchecked Sendable {
    private let listener: LoopbackTCPListener
    private let response: String?
    private let requestReceived = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var requestValue: String?

    var port: UInt16 { UInt16(listener.port) }

    init(response: String? = nil) throws {
        listener = try LoopbackTCPListener()
        self.response = response
        DispatchQueue.global(qos: .userInitiated).async { [self] in serveOneConnection() }
    }

    func waitForRequest(timeout: TimeInterval) -> String? {
        guard requestReceived.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return requestValue
    }

    func waitForFinish(timeout: TimeInterval) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    private func serveOneConnection() {
        let client = accept(listener.fileDescriptor, nil, nil)
        guard client >= 0 else { finished.signal(); return }
        defer { close(client); finished.signal() }

        var request = Data()
        let lineEnding = Data([13, 10])
        var buffer = [UInt8](repeating: 0, count: 512)
        while request.count < 512 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { break }
            request.append(contentsOf: buffer[0..<count])
            if request.range(of: lineEnding) != nil { break }
        }
        lock.lock(); requestValue = String(decoding: request, as: UTF8.self); lock.unlock()
        requestReceived.signal()

        if let response {
            let bytes = Data(response.utf8)
            _ = bytes.withUnsafeBytes { Darwin.send(client, $0.baseAddress, $0.count, 0) }
        } else {
            while recv(client, &buffer, buffer.count, 0) > 0 {}
        }
    }
}

do {
    let subnet = IPv4Subnet("192.168.1.0/24")
    try check(subnet?.network.description == "192.168.1.0", "subnet network")
    try check(subnet?.maskDescription == "255.255.255.0", "subnet mask")
    try check(IPv4Subnet("192.168.1.27/24")?.cidr == "192.168.1.0/24", "IPv4 CIDR normalization")
    try check(IPv4Subnet("192.168.1.0/") == nil && IPv4Subnet("192.168.1.0/24/1") == nil, "IPv4 CIDR rejects empty and extra components")
    try check(IPv6Subnet("2001:db8::1234/64")?.description == "2001:db8::/64", "IPv6 CIDR validates and normalizes network address")
    try check(IPv6Subnet("2001:db8::1/") == nil && IPv6Subnet("2001:db8::1/64/1") == nil, "IPv6 CIDR rejects empty and extra components")
    try check(IPv6Subnet("not::ipv6/64") == nil, "IPv6 CIDR rejects malformed address")
    try check(TCPProbe.parsePorts("22,80-82").count == 4, "port parser")
    let ssh = try SSHCommandBuilder.build(host: "2001:db8::1", port: 2200, username: "netops")
    try check(ssh.executable == "/usr/bin/ssh", "SSH uses system OpenSSH")
    try check(ssh.arguments == ["-tt", "-o", "StrictHostKeyChecking=ask", "-p", "2200", "-l", "netops", "--", "2001:db8::1"], "SSH argument construction")
    try check(ssh.auditTarget == "2001:db8::1", "SSH audit target excludes username")
    try check(!ssh.arguments.contains(where: { $0.localizedCaseInsensitiveContains("password") }), "SSH arguments exclude passwords")
    let keyedSSH = try SSHCommandBuilder.build(host: "127.0.0.1", port: 55223, username: "macbook", identityFile: "/tmp/private key")
    try check(keyedSSH.arguments == ["-tt", "-o", "StrictHostKeyChecking=ask", "-p", "55223", "-i", "/tmp/private key", "-o", "IdentitiesOnly=yes", "-l", "macbook", "--", "127.0.0.1"], "SSH passes selected key as a distinct argv value")
    try check((try? SSHCommandBuilder.build(host: "127.0.0.1", port: 22, identityFile: "/tmp/key\n-oStrictHostKeyChecking=no")) == nil, "SSH rejects control characters in identity paths")
    try check((try? SSHCommandBuilder.build(host: "-oProxyCommand=touch /tmp/pwned", port: 22)) == nil, "SSH rejects option and shell injection in host")
    try check((try? SSHCommandBuilder.build(host: "router.example", port: 65536)) == nil, "SSH rejects invalid port")
    let safeCommandReview = try SSHCommandPolicy.review("show version")
    let editedTemplateReview = try SSHCommandPolicy.review("show version ")
    let writeCommandReview = try SSHCommandPolicy.review("configure terminal")
    try check(safeCommandReview == .readOnly(templateID: "ios-version"), "SSH recognizes exact read-only template")
    try check(editedTemplateReview == .requiresConfirmation, "SSH template edits require confirmation")
    try check(writeCommandReview == .requiresConfirmation, "SSH write command requires confirmation")
    try check((try? SSHCommandPolicy.review("show version\nreload")) == nil, "SSH command rejects line injection")
    try check((try? SSHCommandPolicy.review("show version\u{202E}reboot")) == nil, "SSH command rejects Unicode format controls")
    try check(SSHCommandPolicy.reviewedText("show version\u{202E}reboot").contains("\\u{202E}"), "SSH review text escapes Unicode format controls")
    try check(IPv4("10.0.0.1")?.isPrivate == true, "private address")
    let interfaces = NetworkInterfaces.list(includeLoopback: true)
    print("Network interfaces: \(interfaces.map { "\($0.name)/\($0.family)=\($0.address)" }.joined(separator: ", "))")
    try check(!interfaces.isEmpty, "system network interface inventory")
    try check(interfaces.contains { $0.isLoopback }, "loopback interface inventory")
    try check(!NetworkInterfaces.list().contains { $0.isLoopback }, "loopback filtering")
    try check(DataStore.shared.ouiEntryCount > 100, "OUI data store")
    try check(DataStore.shared.searchPorts("ssh").contains { $0.number == 22 }, "port data store")
    try check((try? HostRangeParser.parse("192.168.1.1-192.168.1.3"))?.count == 3, "host range parser")
    let subnetPreview = try HostRangeParser.preview("192.168.1.0/24")
    try check(subnetPreview == HostRangePreview(count: 254, firstTarget: "192.168.1.1", lastTarget: "192.168.1.254"), "subnet preview reports bounded IPv4 host endpoints")
    let combinedPreview = try HostRangeParser.preview("127.0.0.1,192.168.1.1-3;host.local")
    try check(combinedPreview == HostRangePreview(count: 5, firstTarget: "127.0.0.1", lastTarget: "host.local"), "combined range preview matches target expansion")
    let largePreview = try HostRangeParser.preview("10.0.0.0/8")
    try check(largePreview.count == 16_777_214 && largePreview.firstTarget == "10.0.0.1" && largePreview.lastTarget == "10.255.255.254", "large range preview does not require target expansion")
    do {
        _ = try HostRangeParser.parse("10.0.0.0/8")
        throw CheckFailure(description: "large host range should be rejected before expansion")
    } catch HostRangeError.tooLarge(let count) {
        try check(count == largePreview.count, "host range limit reports the actual target count")
    }
    let sockets = SocketInventory.parse("COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\nnginx 42 root 6u IPv4 0 0 TCP 127.0.0.1:8080 (LISTEN)\ncurl 43 user 7u IPv4 0 0 TCP 127.0.0.1:5000->93.184.216.34:443 (ESTABLISHED)\n")
    try check(sockets.count == 2 && sockets[0].state == "LISTEN", "socket parser")
    let neighbors = NeighborTable.parse("? (192.168.1.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]\n")
    try check(neighbors.first?.macAddress == "AA:BB:CC:DD:EE:FF" && neighbors.first?.interface == "en0", "neighbor parser")
    let route = DefaultRouteInventory.parse("route to: default\ndestination: default\n       gateway: 192.168.1.1\n  interface: en0\n")
    try check(route == DefaultRouteInfo(gateway: "192.168.1.1", interface: "en0"), "default route parser")
    try check(DefaultRouteInventory.parse("interface: en0\n") == nil, "incomplete default route")
    let wifi = WiFiInventory.parse("AirPort:\n  en0:\n    Current Network Information:\n      Office WiFi:\n        BSSID: aa:bb:cc:dd:ee:ff\n        Channel: 36\n        Security: WPA2 Personal\n        Signal / Noise: -50 dBm / -90 dBm\n")
    try check(wifi.first?.bssid == "aa:bb:cc:dd:ee:ff" && wifi.first?.channel == "36", "wifi parser")
    try check(DNSClient.reverseName(for: "192.0.2.1") == "1.2.0.192.in-addr.arpa", "reverse DNS")
    try checkAddressResolutionCancellation()
    let localhostAddresses = try SocketAddressResolver.resolve("localhost", port: 80, timeout: 3)
    try check(localhostAddresses.contains { $0.family == AF_INET && $0.numericAddress == "127.0.0.1" }, "system DNS-SD resolves localhost IPv4")
    try check(localhostAddresses.allSatisfy { $0.length > 0 && $0.bytes.count == Int($0.length) }, "resolved sockaddr values preserve their platform lengths")
    let tcpFixture = try LoopbackTCPListener()
    let resolvedTCP = try awaitNetBoxFixture {
        await DiagnosticService.runTCP(host: "localhost", port: tcpFixture.port, timeout: 1)
    }
    try check(resolvedTCP.status == .succeeded, "TCP diagnostic connects through the cancellable localhost resolver")
    let cancelledPortScan = DiagnosticCancellation()
    cancelledPortScan.cancel()
    let skippedPorts = await TCPProbe.scan(host: "127.0.0.1", ports: [1, 2, 3], timeout: 10, cancellation: cancelledPortScan)
    try check(skippedPorts.isEmpty, "a cancelled port scan starts no probes")
    try check(SNMPValue.integer(7).displayValue == "7", "SNMP value")
    let echoedCommunity = "fixture-community-secret"
    let redactedSNMPValue = DiagnosticSecretRedactor.redact("returned=\(echoedCommunity)", secrets: [echoedCommunity])
    try check(!redactedSNMPValue.contains(echoedCommunity) && redactedSNMPValue.contains("[REDACTED]"), "SNMP diagnostic values redact the active community")
    try SNMPv3OfflineChecks.run()
    let launch = LaunchOptions(arguments: ["NETworkManager", "--application:PingMonitor", "--reset-settings"])
    try check(launch.tool == "ping" && launch.resetSettings, "launch options")
    let isolatedSupport = URL(fileURLWithPath: "/private/tmp/nm-isolated-support", isDirectory: true)
    try check(SettingsStore.resolvedSupportDirectory(environment: ["NETWORKMANAGER_SUPPORT_DIRECTORY": isolatedSupport.path]) == isolatedSupport, "support directory override")
    let defaultSupport = SettingsStore.resolvedSupportDirectory(environment: [:])
    try check(SettingsStore.resolvedSupportDirectory(environment: ["NETWORKMANAGER_SUPPORT_DIRECTORY": "relative/path"]) == defaultSupport, "support directory override requires an absolute path")
    let settingsDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NMSettingsTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: settingsDirectory) }
    let settingsURL = settingsDirectory.appendingPathComponent("settings.json")
    let damagedSettingsData = Data("{ damaged settings".utf8)
    try damagedSettingsData.write(to: settingsURL)
    let settingsStore = SettingsStore(storageURL: settingsURL, managesLoginItem: false)
    try check(settingsStore.recoveryError != nil, "damaged settings enter recovery state")
    settingsStore.showStatusBar = false
    settingsStore.persist()
    let settingsBytesBeforeReset = try Data(contentsOf: settingsURL)
    try check(settingsBytesBeforeReset == damagedSettingsData, "preference edits do not overwrite damaged settings")
    try check(!settingsStore.resetFromCommandLine(), "command-line reset defers when settings are damaged")
    let settingsBytesAfterDeferredReset = try Data(contentsOf: settingsURL)
    try check(settingsBytesAfterDeferredReset == damagedSettingsData, "deferred command-line reset leaves damaged settings untouched")
    settingsStore.reset()
    guard let preservedSettingsURL = settingsStore.preservedCorruptFileURL else {
        throw CheckFailure(description: "settings recovery should preserve the damaged settings file")
    }
    let preservedSettingsData = try Data(contentsOf: preservedSettingsURL)
    let resetSettingsData = try Data(contentsOf: settingsURL)
    try check(settingsStore.recoveryError == nil && settingsStore.showStatusBar, "explicit settings reset restores defaults")
    try check(preservedSettingsData == damagedSettingsData && (try? JSONSerialization.jsonObject(with: resetSettingsData)) != nil, "settings reset keeps a damaged copy and writes valid defaults")
    let profileDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NMTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: profileDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: profileDirectory) }
    let profileStore = ProfileStore(storageURL: profileDirectory.appendingPathComponent("profiles.json"))
    let windowsJSON = Data("""
    {"Groups":[{"Name":"Imported","Profiles":[
      {"Name":"RDP host","RemoteDesktop_Enabled":true,"RemoteDesktop_Host":"rdp.example","RemoteDesktop_Port":3390},
      {"Name":"SSH host","PuTTY_Enabled":true,"PuTTY_ConnectionMode":"SSH","PuTTY_HostOrSerialLine":"ssh.example","PuTTY_PortOrBaud":2222},
      {"Name":"Telnet host","PuTTY_Enabled":true,"PuTTY_ConnectionMode":"Telnet","PuTTY_HostOrSerialLine":"telnet.example"},
      {"Name":"VNC host","TigerVNC_Enabled":true,"TigerVNC_Host":"vnc.example","TigerVNC_Port":5901},
      {"Name":"SNMP host","SNMP_Enabled":true,"SNMP_Host":"snmp.example","SNMP_Port":1161},
      {"Name":"Web host","WebConsole_Enabled":true,"WebConsole_Url":"https://console.example/path"}
    ]}]}
    """.utf8)
    try profileStore.importJSON(windowsJSON, password: nil)
    try check(profileStore.groups.contains("Imported") && profileStore.profiles.count == 6, "Windows JSON profile import")
    try check(profileStore.profiles.contains { $0.proto == .rdp && $0.port == 3390 }, "Windows RDP mapping")
    try check(profileStore.profiles.contains { $0.proto == .ssh && $0.port == 2222 }, "Windows SSH mapping")
    try check(profileStore.profiles.contains { $0.proto == .telnet && $0.port == 23 }, "Windows Telnet mapping")
    try check(profileStore.profiles.contains { $0.proto == .vnc && $0.port == 5901 }, "Windows VNC mapping")
    try check(profileStore.profiles.contains { $0.proto == .snmp && $0.port == 1161 }, "Windows SNMP mapping")
    try check(profileStore.profiles.contains { $0.proto == .https && $0.host == "https://console.example/path" }, "Windows Web Console mapping")
    let legacyJSON = Data("[{\"Name\":\"Legacy\",\"Profiles\":[{\"Name\":\"Legacy SSH\",\"Host\":\"legacy.example\",\"PuTTY_HostOrSerialLine\":\"legacy.example\",\"PuTTY_Enabled\":true}]}]".utf8)
    try profileStore.importJSON(legacyJSON, password: nil)
    try check(profileStore.groups.contains("Legacy") && profileStore.profiles.contains { $0.name == "Legacy SSH" }, "legacy Windows JSON import")
    let windowsXML = Data("""
    <?xml version="1.0" encoding="utf-8"?>
    <ArrayOfGroupInfoSerializable xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <GroupInfoSerializable>
        <Name>XML Group</Name>
        <Profiles>
          <ProfileInfoSerializable><Name>XML RDP</Name><RemoteDesktop_Enabled>true</RemoteDesktop_Enabled><RemoteDesktop_Host>xml-rdp.example</RemoteDesktop_Host></ProfileInfoSerializable>
          <ProfileInfoSerializable><Name>XML Web</Name><WebConsole_Enabled>true</WebConsole_Enabled><WebConsole_Url>http://xml.example</WebConsole_Url></ProfileInfoSerializable>
        </Profiles>
      </GroupInfoSerializable>
    </ArrayOfGroupInfoSerializable>
    """.utf8)
    try profileStore.importJSON(windowsXML, password: nil)
    try check(profileStore.groups.contains("XML Group") && profileStore.profiles.contains { $0.name == "XML RDP" && $0.proto == .rdp }, "Windows XML import")
    let damagedProfilesURL = profileDirectory.appendingPathComponent("damaged-profiles.json")
    let damagedProfilesData = Data("{ damaged profile file".utf8)
    try damagedProfilesData.write(to: damagedProfilesURL)
    let damagedProfileStore = ProfileStore(storageURL: damagedProfilesURL)
    try check(damagedProfileStore.recoveryError != nil && damagedProfileStore.profiles.isEmpty, "damaged profile file enters recovery state")
    damagedProfileStore.save()
    let profileBytesAfterSave = try Data(contentsOf: damagedProfilesURL)
    try check(profileBytesAfterSave == damagedProfilesData, "ordinary profile save preserves damaged data")
    var invalidProfileImportRejected = false
    do {
        try damagedProfileStore.importJSON(Data("{}".utf8), password: nil)
    } catch {
        invalidProfileImportRejected = true
    }
    let profileBytesAfterInvalidImport = try Data(contentsOf: damagedProfilesURL)
    try check(invalidProfileImportRejected && profileBytesAfterInvalidImport == damagedProfilesData && damagedProfileStore.recoveryError != nil, "invalid profile import does not overwrite damaged data")
    try damagedProfileStore.importJSON(windowsJSON, password: nil)
    guard let preservedProfileURL = damagedProfileStore.preservedCorruptFileURL else {
        throw CheckFailure(description: "profile recovery should preserve a named copy of the damaged file")
    }
    let preservedProfileData = try Data(contentsOf: preservedProfileURL)
    try check(damagedProfileStore.recoveryError == nil && damagedProfileStore.profiles.count == 6, "valid profile import restores damaged library")
    try check(preservedProfileData == damagedProfilesData, "profile recovery preserves original damaged file")
    let encrypted = try profileStore.exportJSON(encryptWith: "test-password")
    try check(ProfileCrypto.isEncrypted(encrypted), "encrypted profile export")
    try check(encrypted.starts(with: Data("NME2".utf8)), "new encrypted profile export uses the versioned password-hardening format")
    let encryptedStore = ProfileStore(storageURL: profileDirectory.appendingPathComponent("encrypted.json"))
    try encryptedStore.importJSON(encrypted, password: "test-password")
    try check(encryptedStore.profiles.count == profileStore.profiles.count, "encrypted profile import")
    let legacySalt = Data(repeating: 0x11, count: 16)
    let legacyKey = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data("test-password".utf8)), salt: legacySalt,
                                            info: Data("NETworkManager-Mac-Profiles".utf8), outputByteCount: 32)
    let legacyNonce = try AES.GCM.Nonce(data: Data(repeating: 0x22, count: 12))
    let legacySealed = try AES.GCM.seal(try profileStore.exportJSON(encryptWith: nil), using: legacyKey, nonce: legacyNonce)
    let legacyExport = Data("NME1".utf8) + legacySalt + legacySealed.combined!
    let legacyImportStore = ProfileStore(storageURL: profileDirectory.appendingPathComponent("legacy-encrypted.json"))
    try legacyImportStore.importJSON(legacyExport, password: "test-password")
    try check(legacyImportStore.profiles.count == profileStore.profiles.count, "legacy NME1 profile exports remain importable")
    let assetDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("NMAssetTest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: assetDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: assetDirectory) }
    let auditURL = assetDirectory.appendingPathComponent("operations-audit.json")
    let auditLog = OperationsAuditLog(storageURL: auditURL)
    auditLog.record(target: "router.example", kind: .confirmedCommandSubmitted)
    let auditData = try Data(contentsOf: auditURL)
    let auditJSON = try JSONSerialization.jsonObject(with: auditData) as? [[String: Any]]
    try check(auditJSON?.first.map { Set($0.keys) == Set(["id", "timestamp", "target", "kind"]) } == true, "operation audit stores structured metadata only")
    try check(auditJSON?.first?["target"] as? String == "router.example", "operation audit stores target")
    let reloadedAudit = OperationsAuditLog(storageURL: auditURL)
    try check(reloadedAudit.records.first?.kind == .confirmedCommandSubmitted, "operation audit reload")
    let assetURL = assetDirectory.appendingPathComponent("assets.json")
    let assets = AssetStore(storageURL: assetURL)
    let workspace = OperationsWorkspace(name: "Test operations")
    let site = AssetSite(workspaceID: workspace.id, name: "Lab")
    let device = AssetDevice(siteID: site.id, name: "Test gateway", address: "127.0.0.1", kind: .router)
    assets.upsert(workspace)
    assets.upsert(site)
    assets.upsert(device)
    let runID = assets.beginDiagnostic(deviceID: device.id, kind: .ping, parameters: ["timeout": "1"])
    assets.finishDiagnostic(id: runID, status: .succeeded, summary: "Success", latency: 0.01)
    let standaloneRunID = assets.beginDiagnostic(kind: .whois, target: "example.com", parameters: ["server": "whois.iana.org"])
    assets.finishDiagnostic(id: standaloneRunID, status: .succeeded, summary: "WHOIS response received", source: "WHOIS")
    let restoredAssets = AssetStore(storageURL: assetURL)
    try check(restoredAssets.devices.contains { $0.id == device.id }, "asset persistence")
    try check(restoredAssets.runs(for: device.id).first?.status == .succeeded, "diagnostic persistence")
    try check(restoredAssets.diagnosticRuns.contains { $0.id == standaloneRunID && $0.deviceID == nil }, "standalone diagnostic persistence")
    try check(restoredAssets.runs(in: workspace.id).map(\.id) == [runID], "standalone diagnostics do not acquire a false workspace association")
    let standaloneEvidence = DiagnosticEvidenceExporter.items(runs: restoredAssets.diagnosticRuns.filter { $0.id == standaloneRunID }, devices: restoredAssets.devices).first
    try check(standaloneEvidence?.device == "Standalone diagnostic" && standaloneEvidence?.address == "example.com", "standalone diagnostic evidence retains its target")
    let legacyRunJSON = Data("""
    {"id":"00000000-0000-0000-0000-000000000010","kind":"dns","status":"succeeded","startedAt":0,"parameters":{},"summary":"legacy","detail":"","source":"DNS"}
    """.utf8)
    let legacyRun = try JSONDecoder().decode(DiagnosticRun.self, from: legacyRunJSON)
    try check(legacyRun.deviceID == nil && legacyRun.kind == .dns, "legacy standalone-compatible diagnostic record decoding")
    let backupData = try assets.exportBackup()
    let backupStoreURL = assetDirectory.appendingPathComponent("restored-backup.json")
    let backupStore = AssetStore(storageURL: backupStoreURL)
    try backupStore.importBackup(backupData)
    try check(backupStore.workspaces.contains { $0.id == workspace.id } && backupStore.runs(for: device.id).count == 1, "asset backup round trip")
    let damagedAssetURL = assetDirectory.appendingPathComponent("damaged-assets.json")
    let damagedAssetData = Data("{ definitely not valid JSON".utf8)
    try damagedAssetData.write(to: damagedAssetURL)
    let damagedAssets = AssetStore(storageURL: damagedAssetURL)
    try check(damagedAssets.recoveryError != nil && damagedAssets.workspaces.isEmpty, "damaged assets enter recovery state without seeding an empty workspace")
    damagedAssets.save()
    let damagedDataAfterSave = try Data(contentsOf: damagedAssetURL)
    try check(damagedDataAfterSave == damagedAssetData, "ordinary save preserves the damaged asset file")
    var invalidBackupRejected = false
    do {
        try damagedAssets.importBackup(Data("{}".utf8))
    } catch {
        invalidBackupRejected = true
    }
    let damagedDataAfterInvalidImport = try Data(contentsOf: damagedAssetURL)
    try check(invalidBackupRejected && damagedDataAfterInvalidImport == damagedAssetData && damagedAssets.recoveryError != nil, "invalid backup leaves damaged asset data available for recovery")
    try damagedAssets.importBackup(backupData)
    guard let preservedCorruptURL = damagedAssets.preservedCorruptFileURL else {
        throw CheckFailure(description: "valid backup should retain a named copy of the damaged asset file")
    }
    let preservedCorruptData = try Data(contentsOf: preservedCorruptURL)
    try check(damagedAssets.recoveryError == nil && damagedAssets.devices.contains { $0.id == device.id }, "valid backup restores a damaged asset workspace")
    try check(preservedCorruptData == damagedAssetData, "backup recovery keeps a copy of the original damaged asset data")
    let source = "https://netbox.example/ops"
    let firstFetch = Date(timeIntervalSince1970: 1_710_000_000)
    let externalSnapshot = ExternalAssetSnapshot(source: source, fetchedAt: firstFetch, siteName: "NetBox Lab", deviceName: "edge-01", address: "192.0.2.10", role: "Edge", vendor: "Router")
    try check(!backupStore.containsExternalAsset(externalSnapshot), "external asset preview does not create a local asset")
    let mapperRecord = NetBoxDeviceRecord(
        id: 77,
        name: "edge-01",
        deviceRole: NetBoxReference(display: "Edge"),
        site: NetBoxReference(display: "NetBox Lab"),
        primaryIP4: NetBoxReference(display: "192.0.2.10/24")
    )
    let mappedSnapshot = NetBoxAssetMapper.snapshot(from: mapperRecord, source: source, fetchedAt: firstFetch)
    try check(mappedSnapshot?.address == "192.0.2.10" && mappedSnapshot?.deviceName == "edge-01", "single NetBox device mapping normalizes its primary address")
    let noAddressRecord = NetBoxDeviceRecord(id: 78, name: "unaddressed")
    try check(NetBoxAssetMapper.snapshot(from: noAddressRecord, source: source, fetchedAt: firstFetch) == nil, "NetBox devices without a primary address cannot be imported")
    let sameIdentity = ExternalAssetSnapshot(source: source, fetchedAt: firstFetch, siteName: "netbox lab", deviceName: "renamed-upstream", address: "192.0.2.10")
    try check(externalSnapshot.hasSameIdentity(as: sameIdentity), "external asset identity ignores site and address case")
    try check(!externalSnapshot.hasSameIdentity(as: ExternalAssetSnapshot(source: "https://other.example", fetchedAt: firstFetch, siteName: "NetBox Lab", deviceName: "edge-01", address: "192.0.2.10")), "external asset identity includes source")
    let imported = backupStore.mergeExternalAssets([externalSnapshot])
    try check(imported == 1, "external asset import")
    try check(backupStore.containsExternalAsset(sameIdentity), "asset store preview detects an existing source-site-address identity")
    guard var importedDevice = backupStore.devices.first(where: { $0.source == source }) else {
        throw CheckFailure(description: "external asset import should produce a device")
    }
    try check(importedDevice.name == "edge-01" && importedDevice.address == "192.0.2.10" && importedDevice.sourceFetchedAt == firstFetch, "external asset mapping includes source freshness")
    importedDevice.name = "Local edge alias"
    backupStore.upsert(importedDevice)
    guard let userEditedAt = backupStore.devices.first(where: { $0.source == source })?.updatedAt else {
        throw CheckFailure(description: "local asset edit should update its user-modified timestamp")
    }
    let refreshedAt = firstFetch.addingTimeInterval(3600)
    let importedAgain = backupStore.mergeExternalAssets([ExternalAssetSnapshot(source: source, fetchedAt: refreshedAt, siteName: "NetBox Lab", deviceName: "renamed-upstream", address: "192.0.2.10", role: "New role", vendor: "New vendor")])
    let refreshedDevice = backupStore.devices.first { $0.source == source }
    try check(importedAgain == 0 && refreshedDevice?.name == "Local edge alias", "external refresh preserves user-authored fields")
    try check(refreshedDevice?.updatedAt == userEditedAt && refreshedDevice?.sourceFetchedAt == refreshedAt, "external refresh keeps edit time separate from persisted source freshness")
    let staleRefresh = backupStore.mergeExternalAssets([ExternalAssetSnapshot(source: source, fetchedAt: firstFetch, siteName: "NetBox Lab", deviceName: "stale-upstream", address: "192.0.2.10")])
    let afterStaleRefresh = backupStore.devices.first { $0.source == source }
    try check(staleRefresh == 0 && afterStaleRefresh?.sourceFetchedAt == refreshedAt, "out-of-order external refresh cannot move source freshness backwards")
    let reloadedExternalAssets = AssetStore(storageURL: backupStoreURL)
    let reloadedExternalDevice = reloadedExternalAssets.devices.first { $0.source == source }
    let persistedTimesMatch = reloadedExternalDevice.map {
        abs($0.updatedAt.timeIntervalSince(userEditedAt)) < 1.0 &&
        abs(($0.sourceFetchedAt ?? .distantPast).timeIntervalSince(refreshedAt)) < 0.001
    } ?? false
    try check(
        persistedTimesMatch,
        "external source freshness persists across store reload (recovery=\(String(describing: reloadedExternalAssets.recoveryError)), updated=\(String(describing: reloadedExternalDevice?.updatedAt)), sourceFetched=\(String(describing: reloadedExternalDevice?.sourceFetchedAt)))"
    )
    let legacyDeviceJSON = Data("""
    {"id":"00000000-0000-0000-0000-000000000011","siteID":"00000000-0000-0000-0000-000000000012","name":"legacy","address":"192.0.2.1","kind":"router","createdAt":0,"updatedAt":0}
    """.utf8)
    let legacyAsset = try JSONDecoder().decode(AssetDevice.self, from: legacyDeviceJSON)
    try check(legacyAsset.sourceFetchedAt == nil, "legacy asset records decode without source freshness")
    let secretValues = ["private-community", "swordfish", "token-abc123", "private-key-value", "inline-password", "inline-token", "inline-community", "bearer-secret", "json-password with spaces", "json-token", "json-api-key", "basic-auth-secret", "url-user", "url-password", "cookie-secret", "single-quoted-token"]
    let sensitiveRun = DiagnosticRun(
        deviceID: device.id,
        kind: .snmp,
        status: .failed,
        parameters: ["community": secretValues[0], "password": secretValues[1], "apiToken": secretValues[2], "privateKey": secretValues[3], "api_key": secretValues[10], "sessionCookie": secretValues[14], "endpoint": "https://\(secretValues[12]):\(secretValues[13])@api.example/path"],
        summary: "password=\(secretValues[4]) token: \(secretValues[5]) {\"password\":\"\(secretValues[8])\",\"apiToken\":\"\(secretValues[9])\",\"api_key\":\"\(secretValues[10])\"}",
        detail: "community=\(secretValues[6]) Bearer \(secretValues[7])\nAuthorization: Basic \(secretValues[11])\nCookie: session=\(secretValues[14]); Secure\nPython-style {'token': '\(secretValues[15])'}"
    )
    let evidenceJSON = try DiagnosticEvidenceExporter.json(runs: [sensitiveRun], devices: [device])
    let evidenceText = String(decoding: evidenceJSON, as: UTF8.self)
    let evidenceMarkdown = DiagnosticEvidenceExporter.markdown(runs: [sensitiveRun], devices: [device])
    try check(evidenceText.contains("[REDACTED]"), "diagnostic JSON redaction marker")
    for secret in secretValues {
        try check(!evidenceText.contains(secret), "diagnostic JSON redacts \(secret)")
        try check(!evidenceMarkdown.contains(secret), "diagnostic Markdown redacts \(secret)")
    }
    try check(evidenceMarkdown.contains("SNMP"), "diagnostic markdown export")
    let otherWorkspace = OperationsWorkspace(name: "Second workspace")
    let otherSite = AssetSite(workspaceID: otherWorkspace.id, name: "Remote site")
    let otherDevice = AssetDevice(siteID: otherSite.id, name: "Remote gateway", address: "192.0.2.20", kind: .router)
    assets.upsert(otherWorkspace)
    assets.upsert(otherSite)
    assets.upsert(otherDevice)
    let otherRunID = assets.beginDiagnostic(deviceID: otherDevice.id, kind: .tcp, target: otherDevice.address, parameters: ["port": "443"])
    assets.finishDiagnostic(id: otherRunID, status: .succeeded, summary: "Port 443 open")
    try check(assets.runs(in: workspace.id).map(\.id) == [runID], "diagnostic query by workspace")
    try check(assets.runs(in: otherWorkspace.id).map(\.id) == [otherRunID], "diagnostic query isolates workspace")
    assets.removeDevice(id: device.id)
    let afterRemoval = AssetStore(storageURL: assetURL)
    try check(!afterRemoval.devices.contains { $0.id == device.id } && afterRemoval.runs(for: device.id).isEmpty, "asset cascade removal")
    try check(afterRemoval.diagnosticRuns.contains { $0.id == standaloneRunID && $0.deviceID == nil }, "asset cascade removal preserves standalone diagnostic history")

    let hierarchyStore = AssetStore(storageURL: assetDirectory.appendingPathComponent("asset-hierarchy.json"))
    let hierarchyWorkspace = hierarchyStore.primaryWorkspace!
    let hierarchySite = AssetSite(workspaceID: hierarchyWorkspace.id, name: "Delete lifecycle site")
    let hierarchySubnet = AssetSubnet(siteID: hierarchySite.id, name: "Operations LAN", cidr: "192.0.2.0/24")
    var hierarchyDevice = AssetDevice(siteID: hierarchySite.id, subnetID: hierarchySubnet.id, name: "Hierarchy target", address: "192.0.2.10")
    hierarchyStore.upsert(hierarchySite)
    hierarchyStore.upsert(hierarchySubnet)
    hierarchyStore.upsert(hierarchyDevice)
    let hierarchyRunID = hierarchyStore.beginDiagnostic(deviceID: hierarchyDevice.id, kind: .ping, target: hierarchyDevice.address)
    hierarchyStore.finishDiagnostic(id: hierarchyRunID, status: .succeeded, summary: "Reachable")
    hierarchyStore.removeSubnet(id: hierarchySubnet.id)
    try check(!hierarchyStore.subnets.contains { $0.id == hierarchySubnet.id }, "subnet deletion removes subnet")
    try check(hierarchyStore.devices.first(where: { $0.id == hierarchyDevice.id })?.subnetID == nil, "subnet deletion retains device and clears association")
    try check(hierarchyStore.runs(for: hierarchyDevice.id).contains { $0.id == hierarchyRunID }, "subnet deletion preserves device history")
    let replacementSubnet = AssetSubnet(siteID: hierarchySite.id, name: "Operations LAN", cidr: "192.0.2.0/24")
    hierarchyDevice.subnetID = replacementSubnet.id
    hierarchyStore.upsert(replacementSubnet)
    hierarchyStore.upsert(hierarchyDevice)
    hierarchyStore.removeSite(id: hierarchySite.id)
    let removedHierarchy = AssetStore(storageURL: assetDirectory.appendingPathComponent("asset-hierarchy.json"))
    try check(!removedHierarchy.sites.contains { $0.id == hierarchySite.id } && !removedHierarchy.subnets.contains { $0.siteID == hierarchySite.id }, "site deletion removes its hierarchy")
    try check(!removedHierarchy.devices.contains { $0.id == hierarchyDevice.id } && removedHierarchy.runs(for: hierarchyDevice.id).isEmpty, "site deletion removes device evidence")

    let legacyAssetURL = assetDirectory.appendingPathComponent("legacy-assets.json")
    let legacyAssetJSON = Data("""
    {"workspaces":[{"id":"00000000-0000-0000-0000-000000000001","name":"Legacy","notes":"","createdAt":0,"updatedAt":0}],"sites":[{"id":"00000000-0000-0000-0000-000000000002","workspaceID":"00000000-0000-0000-0000-000000000001","name":"Lab","location":"","notes":""}],"subnets":[],"devices":[{"id":"00000000-0000-0000-0000-000000000003","siteID":"00000000-0000-0000-0000-000000000002","name":"Legacy device","address":"192.0.2.1","kind":"other","vendor":"","role":"","notes":"","createdAt":0,"updatedAt":0}],"diagnosticRuns":[]}
    """.utf8)
    try legacyAssetJSON.write(to: legacyAssetURL)
    let legacyAssets = AssetStore(storageURL: legacyAssetURL)
    try check(legacyAssets.devices.first?.credentialRefID == nil && legacyAssets.devices.first?.name == "Legacy device", "legacy asset compatibility")

    let interruptedURL = assetDirectory.appendingPathComponent("interrupted-assets.json")
    let interruptedStore = AssetStore(storageURL: interruptedURL)
    let recoverySite = AssetSite(workspaceID: interruptedStore.primaryWorkspace!.id, name: "Recovery test")
    let recoveryDevice = AssetDevice(siteID: recoverySite.id, name: "Recovery target", address: "127.0.0.1")
    interruptedStore.upsert(recoverySite)
    interruptedStore.upsert(recoveryDevice)
    let unfinishedID = interruptedStore.beginDiagnostic(deviceID: recoveryDevice.id, kind: .tcp, target: "127.0.0.1", parameters: ["port": "65000", "timeout": "10"])
    let recoveredStore = AssetStore(storageURL: interruptedURL)
    let recoveredRun = recoveredStore.runs(for: recoveryDevice.id).first
    try check(recoveredRun?.id == unfinishedID && recoveredRun?.status == .interrupted && recoveredRun?.finishedAt != nil, "recover interrupted diagnostic after restart")

    var socketPair = [Int32](repeating: 0, count: 2)
    let socketPairResult = socketPair.withUnsafeMutableBufferPointer { socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress!) }
    try check(socketPairResult == 0, "create cancellation test socket pair")
    defer { close(socketPair[0]); close(socketPair[1]) }
    let cancellation = DiagnosticCancellation()
    let cancellationFinished = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        _ = cancellation.waitForReadiness(fd: socketPair[0], events: Int16(POLLIN), timeout: 10)
        cancellationFinished.signal()
    }
    usleep(50_000)
    cancellation.cancel()
    try check(cancellationFinished.wait(timeout: .now() + 1) == .success, "cancel blocked protocol readiness wait promptly")

    let childCancellation = DiagnosticCancellation()
    let childFinished = DispatchSemaphore(value: 0)
    let childResult = DiagnosticStatusBox()
    Task.detached {
        let result = await Shell.run("/bin/sleep", ["10"], timeout: 15, cancellation: childCancellation)
        childResult.set(result.cancelled ? .cancelled : .failed)
        childFinished.signal()
    }
    usleep(50_000)
    childCancellation.cancel()
    try check(childFinished.wait(timeout: .now() + 2) == .success && childResult.get() == .cancelled, "cancelled diagnostic child process exits promptly")

    let serviceResult = DiagnosticStatusBox()
    let serviceFinished = DispatchSemaphore(value: 0)
    let serviceTask = Task.detached {
        let result = await DiagnosticService.runSNMP(host: "127.0.0.1", port: 161, timeout: 10)
        serviceResult.set(result.status)
        serviceFinished.signal()
    }
    usleep(50_000)
    serviceTask.cancel()
    try check(serviceFinished.wait(timeout: .now() + 2) == .success && serviceResult.get() == .cancelled, "cancelled SNMP diagnostic task terminates its transport")

    let whoisFixture = try LoopbackWhoisFixture(response: "domain: example.com\r\n")
    let whoisResponse = try awaitNetBoxFixture {
        await DiagnosticService.runWhois(host: "example.com", server: "127.0.0.1", timeout: 3, port: whoisFixture.port)
    }
    try check(whoisResponse.status == .succeeded && whoisResponse.displayOutput?.contains("domain: example.com") == true,
              "WHOIS diagnostic reads a loopback TCP response")
    try check(whoisFixture.waitForRequest(timeout: 1) == "example.com\r\n", "WHOIS sends one CRLF-terminated query")
    try check(whoisFixture.waitForFinish(timeout: 1), "WHOIS success fixture closes cleanly")

    let pendingWhoisFixture = try LoopbackWhoisFixture()
    let whoisCancellationStatus = DiagnosticStatusBox()
    let whoisCancellationFinished = DispatchSemaphore(value: 0)
    let whoisTask = Task.detached {
        let result = await DiagnosticService.runWhois(host: "example.com", server: "127.0.0.1", timeout: 10,
                                                      port: pendingWhoisFixture.port)
        whoisCancellationStatus.set(result.status)
        whoisCancellationFinished.signal()
    }
    try check(pendingWhoisFixture.waitForRequest(timeout: 2) == "example.com\r\n", "WHOIS cancellation fixture receives a query")
    whoisTask.cancel()
    try check(whoisCancellationFinished.wait(timeout: .now() + 1) == .success && whoisCancellationStatus.get() == .cancelled,
              "WHOIS cancellation closes a pending TCP response promptly")
    try check(pendingWhoisFixture.waitForFinish(timeout: 1), "WHOIS cancellation fixture releases its accepted socket")

    let sntpFixture = try DNSFixtureServer(responseBuilder: { loopbackNTPResponse(for: $0) })
    defer { sntpFixture.stop() }
    let sntpResponse = try awaitNetBoxFixture {
        await DiagnosticService.runSNTP(host: "127.0.0.1", timeout: 3, port: sntpFixture.port)
    }
    try check(sntpResponse.status == .succeeded, "SNTP diagnostic parses a loopback UDP response")

    let pendingSNTPFixture = try DNSFixtureServer()
    defer { pendingSNTPFixture.stop() }
    let sntpCancellationStatus = DiagnosticStatusBox()
    let sntpCancellationFinished = DispatchSemaphore(value: 0)
    let sntpTask = Task.detached {
        let result = await DiagnosticService.runSNTP(host: "127.0.0.1", timeout: 10, port: pendingSNTPFixture.port)
        sntpCancellationStatus.set(result.status)
        sntpCancellationFinished.signal()
    }
    try check(pendingSNTPFixture.waitForQuery(timeout: 2), "SNTP cancellation fixture receives a query")
    sntpTask.cancel()
    try check(sntpCancellationFinished.wait(timeout: .now() + 1) == .success && sntpCancellationStatus.get() == .cancelled,
              "SNTP cancellation interrupts its pending UDP response")

    let credentialURL = assetDirectory.appendingPathComponent("credentials.json")
    let credentialStore = CredentialStore(metadataURL: credentialURL)
    var emptyCredentialLabelRejected = false
    do {
        _ = try credentialStore.create(label: "  ", kind: .token, secret: CredentialSecret(token: "must-not-be-stored"))
    } catch CredentialError.invalidLabel {
        emptyCredentialLabelRejected = true
    }
    try check(emptyCredentialLabelRejected && !FileManager.default.fileExists(atPath: credentialURL.path), "empty credential labels are rejected before persistence")
    let credentialMarker = "credential-secret-\(UUID().uuidString)"
    let credential = try credentialStore.create(label: "Temporary test credential", kind: .snmp, account: "test-user", secret: CredentialSecret(username: "test-user", password: credentialMarker, privacyPassword: "privacy-\(credentialMarker)"))
    defer { try? credentialStore.remove(credential) }
    let metadataText = String(decoding: try Data(contentsOf: credentialURL), as: UTF8.self)
    try check(!metadataText.contains(credentialMarker), "credential metadata excludes Keychain secrets")
    let reloadedCredentialStore = CredentialStore(metadataURL: credentialURL)
    try check(reloadedCredentialStore.references.contains(where: { $0.id == credential.id }), "credential metadata reload")
    let restoredSecret = try reloadedCredentialStore.secret(for: credential)
    try check(restoredSecret.password == credentialMarker && restoredSecret.privacyPassword == "privacy-\(credentialMarker)", "Keychain credential secret readback")

    let credentialDevice = AssetDevice(siteID: site.id, name: "Credential-linked device", address: "127.0.0.1", credentialRefID: credential.id)
    assets.upsert(credentialDevice)
    let reloadedAssetsWithCredential = AssetStore(storageURL: assetURL)
    let linkedDevice = reloadedAssetsWithCredential.devices.first { $0.id == credentialDevice.id }
    let linkedReference = reloadedCredentialStore.references.first { $0.id == linkedDevice?.credentialRefID }
    try check(linkedDevice?.credentialRefID == credential.id && linkedReference?.id == credential.id, "asset credential reference survives independent store reloads")
    let linkedSecret = try reloadedCredentialStore.secret(for: linkedReference!)
    try check(linkedSecret.password == credentialMarker, "reloaded asset credential reference resolves to its Keychain secret")

    let credentialBackup = try reloadedCredentialStore.exportReferences()
    let credentialBackupText = String(decoding: credentialBackup, as: UTF8.self)
    try check(!credentialBackupText.contains(credentialMarker), "credential reference backup excludes Keychain secrets")
    let damagedCredentialURL = assetDirectory.appendingPathComponent("damaged-credentials.json")
    let damagedCredentialData = Data("{ damaged credential metadata".utf8)
    try damagedCredentialData.write(to: damagedCredentialURL)
    let damagedCredentialStore = CredentialStore(metadataURL: damagedCredentialURL)
    try check(damagedCredentialStore.recoveryError != nil && damagedCredentialStore.references.isEmpty, "damaged credential metadata enters recovery state")
    var credentialMutationBlocked = false
    do {
        _ = try damagedCredentialStore.create(label: "Blocked", kind: .token, secret: CredentialSecret(token: "must-not-be-stored"))
    } catch CredentialError.recoveryRequired {
        credentialMutationBlocked = true
    }
    let damagedCredentialAfterMutation = try Data(contentsOf: damagedCredentialURL)
    try check(credentialMutationBlocked && damagedCredentialAfterMutation == damagedCredentialData, "credential creation cannot overwrite damaged metadata")
    var invalidCredentialBackupRejected = false
    do {
        try damagedCredentialStore.restoreReferences(from: Data("[{}]".utf8))
    } catch {
        invalidCredentialBackupRejected = true
    }
    try check(invalidCredentialBackupRejected && damagedCredentialStore.recoveryError != nil, "invalid credential reference backup does not clear recovery state")
    try damagedCredentialStore.restoreReferences(from: credentialBackup)
    guard let preservedCredentialURL = damagedCredentialStore.preservedCorruptFileURL else {
        throw CheckFailure(description: "credential metadata recovery should preserve the damaged source file")
    }
    let preservedCredentialData = try Data(contentsOf: preservedCredentialURL)
    try check(damagedCredentialStore.recoveryError == nil && damagedCredentialStore.references.contains { $0.id == credential.id }, "valid reference backup restores credential metadata")
    try check(preservedCredentialData == damagedCredentialData, "credential metadata recovery preserves original damaged bytes")
    let restoredCredentialSecret = try damagedCredentialStore.secret(for: credential)
    try check(restoredCredentialSecret.password == credentialMarker, "restored credential metadata resolves to the existing Keychain item")

    let missingCredentialURL = assetDirectory.appendingPathComponent("missing-credentials.json")
    let missingCredentialStore = CredentialStore(metadataURL: missingCredentialURL)
    let missingCredential = try missingCredentialStore.create(
        label: "Missing metadata test", kind: .token,
        secret: CredentialSecret(token: "missing-metadata-\(UUID().uuidString)")
    )
    defer { try? missingCredentialStore.remove(missingCredential) }
    let missingCredentialBackup = try missingCredentialStore.exportReferences()
    try FileManager.default.removeItem(at: missingCredentialURL)
    let missingCredentialReload = CredentialStore(metadataURL: missingCredentialURL)
    try check(missingCredentialReload.recoveryError != nil, "missing credential metadata with an initialization marker enters recovery state")
    try missingCredentialReload.restoreReferences(from: missingCredentialBackup)
    try check(missingCredentialReload.recoveryError == nil && missingCredentialReload.references.contains { $0.id == missingCredential.id }, "missing credential metadata restores from a valid reference backup")

    try reloadedCredentialStore.remove(credential)
    try check((try? reloadedCredentialStore.secret(for: credential)) == nil, "Keychain credential removal")

    let dnsFixture = try DNSFixtureServer()
    defer { dnsFixture.stop() }
    let dnsStatus = DiagnosticStatusBox()
    let dnsFinished = DispatchSemaphore(value: 0)
    let dnsTask = Task.detached {
        let result = await DiagnosticService.runDNS(host: "cancel.test", server: "127.0.0.1", serverPort: dnsFixture.port, timeout: 10)
        dnsStatus.set(result.status)
        dnsFinished.signal()
    }
    try check(dnsFixture.waitForQuery(timeout: 2), "DNS cancellation fixture receives the query")
    dnsTask.cancel()
    try check(dnsFinished.wait(timeout: .now() + 1) == .success && dnsStatus.get() == .cancelled, "DNS diagnostic parent cancellation interrupts a pending UDP response")

    let dnsResponseFixture = try DNSFixtureServer(responseBuilder: { DNSFixtureServer.loopbackARecordResponse(for: $0) })
    defer { dnsResponseFixture.stop() }
    let dnsResponse = try awaitNetBoxFixture {
        await DiagnosticService.runDNS(host: "fixture.test", server: "127.0.0.1", serverPort: dnsResponseFixture.port, timeout: 3)
    }
    try check(dnsResponse.status == .succeeded, "DNS local response status \(String(describing: dnsResponse.status)): \(dnsResponse.summary) [\(dnsResponse.detail)]")
    try check(dnsResponse.summary == "1 record(s)", "DNS service formats successful record counts")
    try check(dnsResponse.detail.contains("127.0.0.42"), "DNS service reports the parsed loopback fixture answer")

    let preCancelledTCPStatus = DiagnosticStatusBox()
    let preCancelledTCPFinished = DispatchSemaphore(value: 0)
    let preCancelledTCPTask = Task.detached {
        do { try await Task.sleep(for: .seconds(10)) } catch {}
        let result = await DiagnosticService.runTCP(host: "127.0.0.1", port: 9, timeout: 10)
        preCancelledTCPStatus.set(result.status)
        preCancelledTCPFinished.signal()
    }
    preCancelledTCPTask.cancel()
    try check(preCancelledTCPFinished.wait(timeout: .now() + 2) == .success && preCancelledTCPStatus.get() == .cancelled, "TCP diagnostic started from a cancelled parent task remains cancelled")

    try NetBoxOfflineChecks.run()
    try NetBoxHTTPChecks.run()
    try ZabbixHTTPChecks.run()
    if let pinger = try? ICMPPinger(host: "127.0.0.1", timeout: 0.8) {
        try check(pinger.ping().outcome.isSuccess, "localhost ICMP")
    }
    let cancelledPing = DiagnosticCancellation()
    let cancelledPinger = try ICMPPinger(host: "127.0.0.1", timeout: 10, cancellation: cancelledPing)
    cancelledPing.cancel()
    let cancelStartedAt = Date()
    let cancelledReply = cancelledPinger.ping()
    try check(Date().timeIntervalSince(cancelStartedAt) < 0.1, "a cancelled ICMP probe exits before sending")
    if case .error(let message) = cancelledReply.outcome {
        try check(message == t("Diagnostic cancelled"), "a cancelled ICMP probe reports cancellation")
    } else {
        throw CheckFailure(description: "a cancelled ICMP probe should not fall back or report a timeout")
    }
    print("NMTest: all checks passed")
} catch {
    fputs("NMTest: FAILED: \(error)\n", stderr)
    exit(1)
}
