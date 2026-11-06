import Foundation
import NMCore

print("NETworkManager macOS self-test")
let sampleSubnet = IPv4Subnet("192.168.1.0/24")?.cidr ?? "invalid"
print("IPv4: \(sampleSubnet)")
do {
    try SNMPv3OfflineChecks.run()
    print("SNMPv3 crypto vectors: passed")
} catch {
    fputs("SNMPv3 crypto vectors: failed: \(error)\n", stderr)
    exit(1)
}
