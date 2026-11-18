import Foundation
import Darwin
@testable import NMCore

/// Optional scale fixture. It uses no operator data and is separate from the
/// correctness suite so CI does not confuse machine speed with data safety.
enum AssetRepositoryBenchmark {
    static func run(reportURL: URL?) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMStorageBenchmark-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = OperationsWorkspace(name: "Benchmark")
        let site = AssetSite(workspaceID: workspace.id, name: "Fixture")
        let devices = (0..<10_000).map { AssetDevice(siteID: site.id, name: "Device \($0)", address: "fixture-\($0)") }
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let runs = (0..<100_000).map { index in
            DiagnosticRun(deviceID: devices[index % devices.count].id, kind: .tcp, status: .succeeded,
                          startedAt: start.addingTimeInterval(Double(index)), finishedAt: start.addingTimeInterval(Double(index) + 0.01),
                          parameters: ["port": "443"], summary: "TCP fixture", detail: String(repeating: "fixture ", count: 24),
                          latency: 0.01, source: "benchmark", target: devices[index % devices.count].address)
        }
        var snapshot = AssetSnapshot(workspaces: [workspace], sites: [site], devices: devices, diagnosticRuns: runs)
        let repository = SQLiteAssetRepository(url: directory.appendingPathComponent("assets.sqlite"))
        _ = try repository.load()
        let importMS = try measured { try repository.save(snapshot) }
        let reloadMS = try measured {
            let restored = try repository.load()
            try check(restored == snapshot, "Scale fixture restores all 10k devices and 100k complete runs")
        }
        snapshot.diagnosticRuns[99_999].summary = "Incremental update"
        let singleUpdateMS = try measured { try repository.save(snapshot) }
        var metrics: [String: [String: Double]] = [:]
        for (name, scope) in [("all", DiagnosticPageQuery.Scope.all), ("workspace", .workspace(workspace.id))] {
            for _ in 0..<5 { _ = try repository.diagnosticPage(DiagnosticPageQuery(scope: scope)) }
            var samples: [Double] = []
            for index in 0..<100 {
                let offset = (index * 997) % 99_950
                let duration = try measured {
                    let page = try repository.diagnosticPage(DiagnosticPageQuery(scope: scope, limit: 50, offset: offset))
                    try check(page.count == 50, "Scale fixture returns a complete 50-row page")
                }
                samples.append(duration)
            }
            samples.sort()
            metrics[name] = ["p50_ms": samples[49], "p95_ms": samples[94], "max_ms": samples[99]]
        }
        let report: [String: Any] = [
            "schemaVersion": 1, "measuredAt": ISO8601DateFormatter().string(from: Date()),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "hardwareModel": sysctlString("hw.model"), "cpu": sysctlString("machdep.cpu.brand_string"),
            "devices": 10_000, "runs": 100_000, "pageSize": 50, "samplesPerScope": 100,
            "warmupPerScope": 5, "configuration": configuration,
            "import_ms": importMS, "full_reload_ms": reloadMS, "single_row_update_ms": singleUpdateMS,
            "pagination": metrics,
            "limits": "Repository API benchmark; GUI still retains full in-memory arrays and synchronously waits for commits."
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        if let reportURL { try data.write(to: reportURL, options: .atomic) }
        print(String(decoding: data, as: UTF8.self))
    }

    private static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release (-O; testable modules enabled)"
        #endif
    }

    private static func measured(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func sysctlString(_ name: String) -> String {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return "unknown" }
        return String(cString: bytes)
    }
}
