import Foundation
import Darwin

/// Access failures happen before opening the database and must never offer
/// damaged-data recovery, which could replace a live owner's workspace.
public enum AssetWorkspaceAccessError: LocalizedError {
    case inUse
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .inUse:
            return t("Another NETworkManager instance is using this asset workspace. Quit that instance, then retry opening the workspace.")
        case .unavailable(let message):
            return tf("The asset workspace cannot be accessed. Check its folder permissions, then retry. (%@)", message)
        }
    }
}

/// A separate, stable inode from the per-operation repository lock. Never
/// unlink it: doing so would let another process lock a different inode.
/// The repository retains this descriptor for its lifetime; the kernel also
/// releases it when its process exits, including abnormal termination.
final class AssetWorkspaceOwnership {
    private let url: URL
    private var descriptor: Int32?

    init(databaseURL: URL) {
        url = databaseURL.appendingPathExtension("owner.lock")
    }

    func acquire() throws {
        guard descriptor == nil else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw AssetWorkspaceAccessError.unavailable(error.localizedDescription)
        }
        let candidate = Darwin.open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard candidate >= 0 else {
            throw AssetWorkspaceAccessError.unavailable(Self.message(errno))
        }
        guard flock(candidate, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            Darwin.close(candidate)
            if code == EWOULDBLOCK || code == EAGAIN { throw AssetWorkspaceAccessError.inUse }
            throw AssetWorkspaceAccessError.unavailable(Self.message(code))
        }
        descriptor = candidate
    }

    deinit {
        if let descriptor { Darwin.close(descriptor) }
    }

    private static func message(_ code: Int32) -> String {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code)).localizedDescription
    }
}
