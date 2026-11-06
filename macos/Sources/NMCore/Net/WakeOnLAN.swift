import Foundation

public enum WakeOnLAN {
    public static func send(macAddress: String, broadcastAddress: String = "255.255.255.255", port: Int = 9) -> Result<Void, Error> {
        let bytes = macAddress.filter(\.isHexDigit)
        guard bytes.count == 12 else { return .failure(WOLError.invalidMAC) }
        var mac: [UInt8] = []
        for index in stride(from: 0, to: 12, by: 2) {
            guard let byte = UInt8(bytes[String.Index(utf16Offset: index, in: bytes)..<String.Index(utf16Offset: index + 2, in: bytes)], radix: 16) else {
                return .failure(WOLError.invalidMAC)
            }
            mac.append(byte)
        }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)) }
        defer { Darwin.close(fd) }
        var enable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(clamping: port).bigEndian
        inet_pton(AF_INET, broadcastAddress, &address.sin_addr)
        let sent = packet.withUnsafeBytes { raw in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        return sent == packet.count ? .success(()) : .failure(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
    }

    public enum WOLError: LocalizedError {
        case invalidMAC
        public var errorDescription: String? { t("Enter a valid MAC address, for example AA:BB:CC:DD:EE:FF.") }
    }
}
