import CPcap
import CryptoKit
import Darwin
import Foundation

public struct PacketCaptureSummary: Codable, Equatable, Sendable {
    public static let maximumBytes = 64 * 1_024 * 1_024
    public let schemaVersion: Int
    public let fileBytes: Int
    public let packets: Int
    public let sha256: String
    public let parser: String

    public enum Failure: Error {
        case unreadable
        case tooLarge
        case invalidCapture
        case modifiedDuringRead
        case timedOut
    }

    public static func analyze(_ url: URL) async throws -> Self {
        let cancellation = DiagnosticCancellation()
        return try await withTaskCancellationHandler {
            let result = await runBlockingDiagnostic {
                Result {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    return try read(url, cancellation: cancellation)
                }
            }
            return try result.get()
        } onCancel: {
            cancellation.cancel()
        }
    }

    public static func read(_ url: URL, cancellation: DiagnosticCancellation? = nil) throws -> Self {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        func checkProgress() throws {
            if cancellation?.isCancelled == true || Task.isCancelled { throw CancellationError() }
            if ProcessInfo.processInfo.systemUptime >= deadline { throw Failure.timedOut }
        }

        try checkProgress()
        guard url.isFileURL else { throw Failure.unreadable }
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        guard initial.st_size <= maximumBytes else { throw Failure.tooLarge }

        var digest = SHA256()
        var bytes = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
            try checkProgress()
            if bytes == 0 && !chunk.starts(with: [0x0a, 0x0d, 0x0d, 0x0a]) { throw Failure.invalidCapture }
            bytes += chunk.count
            guard bytes <= maximumBytes else { throw Failure.tooLarge }
            digest.update(data: chunk)
        }
        guard bytes >= 28 else { throw Failure.invalidCapture }
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw Failure.unreadable }

        // libpcap owns the FILE stream after a successful open.
        let captureFD = fcntl(fd, F_DUPFD_CLOEXEC, 0)
        guard captureFD >= 0 else { throw Failure.unreadable }
        guard let stream = fdopen(captureFD, "rb") else {
            close(captureFD)
            throw Failure.unreadable
        }
        var errors = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        guard let capture = pcap_fopen_offline(stream, &errors) else {
            fclose(stream)
            throw Failure.invalidCapture
        }
        defer { pcap_close(capture) }
        var packets = 0
        var header: UnsafeMutablePointer<pcap_pkthdr>?
        var payload: UnsafePointer<UInt8>?
        while true {
            try checkProgress()
            let result = pcap_next_ex(capture, &header, &payload)
            if result == -2 { break }
            guard result == 1 else { throw Failure.invalidCapture }
            packets += 1
        }

        var final = stat()
        guard fstat(fd, &final) == 0, bytes == initial.st_size, bytes == final.st_size,
              initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
              initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
              initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else { throw Failure.modifiedDuringRead }
        try checkProgress()
        return Self(schemaVersion: 1, fileBytes: bytes, packets: packets,
                    sha256: digest.finalize().map { String(format: "%02x", $0) }.joined(),
                    parser: String(cString: pcap_lib_version()))
    }
}

extension PacketCaptureSummary {
    public static func importJSON(from url: URL) throws -> Self {
        let maximumJSONBytes = 4_096
        guard url.isFileURL else { throw Failure.unreadable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.unreadable }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure.unreadable }
        guard info.st_size <= maximumJSONBytes,
              let data = try handle.read(upToCount: maximumJSONBytes + 1),
              data.count <= maximumJSONBytes else { throw Failure.tooLarge }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
        fileBytes = try fields.decode(Int.self, forKey: .fileBytes)
        packets = try fields.decode(Int.self, forKey: .packets)
        sha256 = try fields.decode(String.self, forKey: .sha256)
        parser = try fields.decode(String.self, forKey: .parser)
        let parserCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .()+,_-")
        guard schemaVersion == 1, (28...Self.maximumBytes).contains(fileBytes),
              (0...(fileBytes / 12)).contains(packets),
              sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              parser.hasPrefix("libpcap version "), parser.utf8.count <= 128,
              !parser.dropFirst("libpcap version ".count).isEmpty,
              parser.unicodeScalars.allSatisfy(parserCharacters.contains) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                     debugDescription: "Invalid packet capture summary metadata."))
        }
    }
}
