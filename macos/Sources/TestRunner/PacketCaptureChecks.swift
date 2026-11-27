import Darwin
import Foundation
import NMCore

enum PacketCaptureChecks {
    static func inFlightCancellation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMPacketCancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("cancel.pcapng")
        let header = Data([
            0x0a, 0x0d, 0x0d, 0x0a, 28, 0, 0, 0, 0x4d, 0x3c, 0x2b, 0x1a, 1, 0, 0, 0,
            255, 255, 255, 255, 255, 255, 255, 255, 28, 0, 0, 0,
            1, 0, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 255, 255, 0, 0, 20, 0, 0, 0,
        ])
        let packet = Data([
            6, 0, 0, 0, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0, 16, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48, 0, 0, 0,
        ])
        var batch = Data()
        for _ in 0..<1024 { batch.append(packet) }
        let batchCount = (PacketCaptureSummary.maximumBytes - header.count) / batch.count
        try header.write(to: url)
        let writer = try FileHandle(forWritingTo: url)
        do {
            defer { try? writer.close() }
            try writer.seekToEnd()
            for _ in 0..<batchCount { try writer.write(contentsOf: batch) }
        }
        var source = stat()
        try check(stat(url.path, &source) == 0, "Could not identify the capture fixture")

        let analysis = Task { try await PacketCaptureSummary.analyze(url) }
        defer { analysis.cancel() }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        var openedForAnalysis = isOpen(source)
        while !openedForAnalysis, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(1))
            openedForAnalysis = isOpen(source)
        }
        analysis.cancel()
        do {
            _ = try await analysis.value
            throw CheckFailure(description: "Capture analysis completed after in-flight cancellation")
        } catch is CancellationError {}
        try check(openedForAnalysis && !isOpen(source), "Cancellation must follow opening and release the capture descriptor")
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        try check(size == header.count + batchCount * batch.count, "Cancellation leaves the source capture in place")
    }

    private static func isOpen(_ source: stat) -> Bool {
        var candidate = stat()
        for fd in 0..<128 where fstat(Int32(fd), &candidate) == 0 {
            if candidate.st_dev == source.st_dev, candidate.st_ino == source.st_ino { return true }
        }
        return false
    }

    static func caseAttachment() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMCaptureCase-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureURL = directory.appendingPathComponent("private-capture.pcapng")
        let summaryURL = directory.appendingPathComponent("private-summary.json")
        let projectURL = directory.appendingPathComponent("case.nmfieldproject")
        let libraryURL = directory.appendingPathComponent("case.sqlite")
        let capture = Data([
            0x0a, 0x0d, 0x0d, 0x0a, 28, 0, 0, 0, 0x4d, 0x3c, 0x2b, 0x1a, 1, 0, 0, 0,
            255, 255, 255, 255, 255, 255, 255, 255, 28, 0, 0, 0,
            1, 0, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 255, 255, 0, 0, 20, 0, 0, 0,
            6, 0, 0, 0, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0, 16, 0, 0, 0,
        ]) + Data("fixture-secret!!".utf8) + Data([48, 0, 0, 0])
        try capture.write(to: captureURL)
        let summary = try PacketCaptureSummary.read(captureURL)
        let summaryData = try JSONEncoder().encode(summary)
        try summaryData.write(to: summaryURL)
        let imported = try PacketCaptureSummary.importJSON(from: summaryURL)
        try check(imported == summary, "The published summary is eligible for Case import")

        var project = FieldProject()
        let legacy = FieldIncidentEntry(kind: .note, author: "Engineer", detail: "Existing note")
        let incident = FieldIncident(title: "Capture incident", owner: "Engineer", entries: [legacy])
        try project.saveIncident(incident)
        let oldProject = try FieldProject.decode(project.encoded())
        try check(oldProject.incidents.first?.entries == [legacy], "An existing v4 incident decodes without capture evidence")

        let time = Date(timeIntervalSince1970: 1_800_000_000)
        let entry = FieldIncidentEntry(kind: .note, occurredAt: time, recordedAt: time, author: "Local import",
                                       detail: "Packet capture summary", packetCaptureSummary: imported)
        try project.appendIncidentEntry(entry, to: incident.id)
        let encoded = try project.encoded()
        try encoded.write(to: projectURL)
        let reopened = try FieldProject.decode(Data(contentsOf: projectURL))
        try check(reopened == project && reopened.incidents.first?.entries.last == entry,
                  "Project save and reopen retain summary metadata and import time")

        guard var payload = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
            throw CheckFailure(description: "Capture Case project did not encode to a JSON object")
        }
        try check(payload["schemaVersion"] as? Int == 8, "Capture evidence upgrades the project schema")
        payload["schemaVersion"] = 7
        let downgraded = try JSONSerialization.data(withJSONObject: payload)
        do {
            _ = try FieldProject.decode(downgraded)
            throw CheckFailure(description: "Schema 7 accepted capture evidence")
        } catch FieldIncidentError.invalidRecord {}

        let library = FieldCaseLibrary(url: libraryURL)
        let revision = try library.importProject(reopened, from: projectURL, expectedRevision: nil)
        let reopenedLibrary = FieldCaseLibrary(url: libraryURL)
        let page = try reopenedLibrary.search(FieldIncidentQuery())
        guard let result = page.results.first else { throw CheckFailure(description: "The Case library lost the import") }
        let timeline = try reopenedLibrary.observations(for: result.id)
        try check(timeline == result.incident.timeline && timeline.contains(entry), "Both Case library read paths retain the same evidence")

        let jsonData = try FieldIncidentExporter.json(for: result.incident, retestRuns: [])
        let json = String(decoding: jsonData, as: UTF8.self)
        let markdown = FieldIncidentExporter.markdown(for: result.incident, retestRuns: [])
        let exported = try JSONDecoder().decode(LegacyCaseSnapshot.self, from: jsonData)
        try check(exported.schemaVersion == 1 && exported.observations.allSatisfy { $0.kind == .note },
                  "The legacy Case snapshot header and Observation kinds remain compatible")
        try check(json.contains(summary.sha256) && json.contains("packetCaptureSummary") &&
                  markdown.contains(summary.sha256) && markdown.contains("2027-01-15T08:00:00Z"),
                  "Both Case export formats capture the digest and import time")
        for export in [String(decoding: encoded, as: UTF8.self), json, markdown] {
            try check(!export.contains("private-capture") && !export.contains("private-summary") &&
                      !export.contains("fixture-secret"), "Project and Case exports omit source paths and packet payload")
        }

        try project.removePacketCaptureSummary(legacy.id, from: incident.id)
        try project.removePacketCaptureSummary(entry.id, from: incident.id)
        let afterRemoval = try FieldProject.decode(project.encoded())
        try check(afterRemoval.incidents.first?.entries == [legacy], "Removal preserves ordinary timeline notes")
        try afterRemoval.encoded().write(to: projectURL)
        _ = try reopenedLibrary.importProject(afterRemoval, from: projectURL, expectedRevision: revision)
        let updated = try reopenedLibrary.observations(for: result.id)
        let sourceCapture = try Data(contentsOf: captureURL)
        let sourceSummary = try Data(contentsOf: summaryURL)
        try check(updated == [legacy] && sourceCapture == capture && sourceSummary == summaryData,
                  "Library refresh clears removed evidence and preserves both original files")

        guard var invalid = try JSONSerialization.jsonObject(with: summaryData) as? [String: Any] else {
            throw CheckFailure(description: "Capture summary did not encode to a JSON object")
        }
        invalid["parser"] = "libpcap version /private/capture/source"
        try JSONSerialization.data(withJSONObject: invalid).write(to: summaryURL)
        do {
            _ = try PacketCaptureSummary.importJSON(from: summaryURL)
            throw CheckFailure(description: "Invalid parser metadata entered the Case attachment")
        } catch DecodingError.dataCorrupted {}
    }

    private struct LegacyCaseSnapshot: Decodable {
        let schemaVersion: Int
        let observations: [Observation]

        struct Observation: Decodable {
            let kind: FieldIncidentEntryKind
        }
    }

    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NMPacketCapture-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sensitive-path.pcapng")
        var capture = Data([
            0x0a, 0x0d, 0x0d, 0x0a, 28, 0, 0, 0, 0x4d, 0x3c, 0x2b, 0x1a, 1, 0, 0, 0,
            255, 255, 255, 255, 255, 255, 255, 255, 28, 0, 0, 0,
            1, 0, 0, 0, 20, 0, 0, 0, 1, 0, 0, 0, 255, 255, 0, 0, 20, 0, 0, 0,
            6, 0, 0, 0, 48, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0, 16, 0, 0, 0,
        ])
        capture.append(contentsOf: "fixture-secret!!".utf8)
        capture.append(contentsOf: [48, 0, 0, 0])
        try capture.write(to: url)
        let summary = try PacketCaptureSummary.read(url)
        try check(summary.packets == 1 && summary.fileBytes == capture.count && summary.schemaVersion == 1 &&
                  summary.sha256 == "a7da963507f909b594af726d25a0206e94c96431a028cf1a6a17c0d62036b148" &&
                  !summary.parser.isEmpty, "Offline packet summary keeps the verified byte count and digest")
        let report = String(decoding: try JSONEncoder().encode(summary), as: UTF8.self)
        let original = try Data(contentsOf: url)
        try check(!report.contains("sensitive-path") && !report.contains("fixture-secret") && original == capture,
                  "Summary omits the path and packet content and preserves the original")

        let bigEndian = Data([
            // Section header and two Ethernet interfaces with the same snap length.
            0x0a, 0x0d, 0x0d, 0x0a, 0, 0, 0, 28, 0x1a, 0x2b, 0x3c, 0x4d, 0, 1, 0, 0,
            255, 255, 255, 255, 255, 255, 255, 255, 0, 0, 0, 28,
            0, 0, 0, 1, 0, 0, 0, 20, 0, 1, 0, 0, 0, 0, 255, 255, 0, 0, 0, 20,
            0, 0, 0, 1, 0, 0, 0, 20, 0, 1, 0, 0, 0, 0, 255, 255, 0, 0, 0, 20,
            // Simple Packet Block uses the first interface. Enhanced Packet Block names the second.
            0, 0, 0, 3, 0, 0, 0, 32, 0, 0, 0, 16,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 32,
            0, 0, 0, 6, 0, 0, 0, 48, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 16, 0, 0, 0, 16,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 48,
        ])
        try bigEndian.write(to: url)
        let bigEndianSummary = try PacketCaptureSummary.read(url)
        try check(bigEndianSummary.packets == 2 && bigEndianSummary.fileBytes == bigEndian.count,
                  "Big-endian pcapng counts the packets from both interfaces and block kinds")

        let cancellation = DiagnosticCancellation()
        cancellation.cancel()
        do {
            _ = try PacketCaptureSummary.read(url, cancellation: cancellation)
            throw CheckFailure(description: "Cancelled capture analysis succeeded")
        } catch is CancellationError {}

        try capture.dropLast().write(to: url)
        do {
            _ = try PacketCaptureSummary.read(url)
            throw CheckFailure(description: "A truncated pcapng block passed analysis")
        } catch PacketCaptureSummary.Failure.invalidCapture {}
        try Data("not a packet capture".utf8).write(to: url)
        do {
            _ = try PacketCaptureSummary.read(url)
            throw CheckFailure(description: "A foreign format passed pcapng analysis")
        } catch PacketCaptureSummary.Failure.invalidCapture {}
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: UInt64(PacketCaptureSummary.maximumBytes + 1))
        try file.close()
        do {
            _ = try PacketCaptureSummary.read(url)
            throw CheckFailure(description: "An oversized capture passed analysis")
        } catch PacketCaptureSummary.Failure.tooLarge {}
    }
}
