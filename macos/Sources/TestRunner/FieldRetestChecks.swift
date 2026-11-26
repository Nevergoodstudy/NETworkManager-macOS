import Foundation
import Darwin
@testable import NMCore

enum FieldRetestChecks {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func run() throws {
        let encodedType = try JSONEncoder().encode(DNSRecordType.aaaa)
        let decodedType = try JSONDecoder().decode(DNSRecordType.self, from: encodedType)
        let encodedMode = try JSONEncoder().encode(DNSLookupMode.system)
        let decodedMode = try JSONDecoder().decode(DNSLookupMode.self, from: encodedMode)
        try check(decodedType == .aaaa && decodedMode == .system,
                  "DNS enums retain their raw values through Codable round trips")

        try requestValidation()
        try incidentPreparation()
        try completedRecordMapping()
        try projectPersistence()
        try baselineReferences()
    }

    static func incidentPreparation() throws {
        let revisionID = UUID()
        let device = AssetDevice(siteID: UUID(), name: "edge-r1", address: "192.0.2.44")
        let incident = FieldIncident(
            title: "Intermittent service", owner: "Engineer", baselineRevisionID: revisionID,
            asset: FieldIncidentAssetReference(device: device)
        )
        let preparation = FieldRetestPreparation(incident: incident)
        var request = FieldRetestRequest(
            acceptanceItemID: UUID(), baselineRevisionID: UUID(), baselineEvidenceID: UUID(),
            target: "previous.example", method: .http,
            dnsRecordType: .aaaa, dnsServer: "192.0.2.53", dnsServerPort: 5353, tcpPort: 8443,
            authorization: FieldRetestAuthorization(reference: "OLD-CHANGE", confirmedBy: "Previous engineer", confirmed: true),
            networkContext: "Previous network conditions", baselineNetworkContext: "Previous baseline",
            baselineAddressFamily: .ipv6, baselineTarget: "previous.example", baselineMethod: .http,
            httpScheme: "http", httpPath: "/previous"
        )
        let previousID = request.id

        request.prepare(for: preparation)

        try check(preparation.incidentID == incident.id && preparation.revisionID == revisionID &&
                  preparation.target == "192.0.2.44",
                  "incident preparation carries its linked revision and asset address")
        try check(request.baselineRevisionID == revisionID && request.target == "192.0.2.44" &&
                  request.acceptanceItemID == nil && request.baselineEvidenceID == nil,
                  "preparing from an incident keeps its revision and target but leaves the handoff row unselected")
        try check(request.authorization.reference.isEmpty && request.authorization.confirmedBy.isEmpty &&
                  !request.authorization.confirmed && request.networkContext.isEmpty &&
                  request.method == .systemDNS,
                  "incident preparation clears prior authorization and network conditions")
        try check(request.id != previousID && request.baselineNetworkContext.isEmpty &&
                  request.baselineAddressFamily == nil && request.baselineTarget == nil && request.baselineMethod == nil &&
                  request.dnsRecordType == .a && request.dnsServer == nil && request.dnsServerPort == 53 &&
                  request.tcpPort == nil && request.httpScheme == nil && request.httpPath == nil,
                  "incident preparation creates a fresh request without hidden inputs from the previous method")

        request.prepare(for: FieldRetestPreparation(incident: FieldIncident(title: "Unassociated", owner: "Engineer")))
        try check(request.baselineRevisionID == nil && request.target.isEmpty,
                  "an unassociated incident does not retain a previously prepared revision or target")
    }

    private static func requestValidation() throws {
        try validRequest().validate(now: now)
        try validRequest(method: .systemDNS, recordType: .aaaa).validate(now: now)
        try validRequest(method: .tcp, port: 443).validate(now: now)
        try validRequest(target: "2001:db8::15", method: .directTCP, port: 443).validate(now: now)
        try validRequest(method: .specifiedDNS, server: "192.0.2.53", serverPort: 5353).validate(now: now)

        var switched = validRequest(method: .specifiedDNS, server: "192.0.2.53")
        switched.selectMethod(.tcp)
        try check(switched.dnsServer == nil && switched.tcpPort == 443,
                  "switching to TCP clears DNS-only inputs and applies the visible default port")
        switched.selectMethod(.systemDNS)
        try check(switched.dnsServer == nil && switched.tcpPort == nil,
                  "switching back to system DNS removes stale TCP inputs")

        for target in ["", "one.example,two.example", "https://one.example", "one.example/path", "one.example name"] {
            var request = validRequest()
            request.target = target
            try expect(.invalidTarget, request)
        }

        var missingAuthorization = validRequest()
        missingAuthorization.authorization.confirmed = false
        try expect(.authorizationRequired, missingAuthorization)
        var notYetConfirmed = validRequest()
        notYetConfirmed.authorization.confirmedAt = now.addingTimeInterval(1)
        try expect(.authorizationRequired, notYetConfirmed)
        var outsideWindow = validRequest()
        outsideWindow.authorization.windowEnd = now.addingTimeInterval(-1)
        try expect(.outsideWindow, outsideWindow)
        var reversedWindow = validRequest()
        reversedWindow.authorization.windowStart = now.addingTimeInterval(2)
        reversedWindow.authorization.windowEnd = now.addingTimeInterval(1)
        try expect(.invalidWindow, reversedWindow)
        var longContext = validRequest()
        longContext.networkContext = String(repeating: "x", count: 501)
        try expect(.contextTooLong, longContext)

        var systemWithServer = validRequest()
        systemWithServer.dnsServer = "192.0.2.53"
        try expect(.serverNotAllowed, systemWithServer)
        var unsupportedSystemType = validRequest()
        unsupportedSystemType.dnsRecordType = .mx
        try expect(.systemDNSRecordType, unsupportedSystemType)
        try expect(.serverRequired, validRequest(method: .specifiedDNS))
        try expect(.directIPRequired, validRequest(target: "service.example", method: .directTCP, port: 443))
        try expect(.invalidPort, validRequest(method: .tcp, port: 65_536))
    }

    private static func completedRecordMapping() throws {
        let startedAt = now
        let finishedAt = now.addingTimeInterval(0.5)
        var baselineRequest = validRequest(
            method: .systemDNS,
            baselineRevisionID: UUID(),
            acceptanceItemID: UUID(),
            baselineEvidenceID: UUID()
        )
        baselineRequest.baselineTarget = "service.example"
        baselineRequest.baselineMethod = .systemDNS

        let dns = DiagnosticExecutionResult(
            status: .succeeded,
            summary: "password=fixture-secret",
            detail: "token=fixture-token",
            dnsRecords: [DNSRecord(name: "service.example", type: .a, ttl: 60, value: "192.0.2.15")]
        )
        let dnsRecord = FieldRetestExecutor.completedRecord(
            request: baselineRequest, result: dns, runID: UUID(), startedAt: startedAt, finishedAt: finishedAt
        )
        try dnsRecord.validate()
        try check(dnsRecord.status == .succeeded && dnsRecord.executedLayers == [.dns] &&
                  dnsRecord.addressFamily == .ipv4 && dnsRecord.dnsMode == .system,
                  "DNS completion records its status, layer, address family, and resolver mode")
        try check(dnsRecord.summary.contains("[REDACTED]") && dnsRecord.detail.contains("[REDACTED]"),
                  "completed DNS output is redacted before it is stored")
        try check(dnsRecord.comparisonState == .notComparable &&
                  dnsRecord.notComparableReason == t("Entered conditions match, but the network route and interface have not been verified."),
                  "matching DNS baseline metadata stays incomparable until route and interface are measured")

        var tcpRequest = validRequest(method: .tcp, port: 443)
        tcpRequest.target = "service.example"
        let attempt = TCPProbeAttempt(address: "192.0.2.21", family: AF_INET, stage: .connect, elapsed: 0.1)
        let tcp = DiagnosticExecutionResult(
            status: .succeeded,
            summary: "Connected",
            evidence: DiagnosticRuntimeEvidence(tcpAttempts: [attempt])
        )
        let tcpRecord = FieldRetestExecutor.completedRecord(
            request: tcpRequest, result: tcp, runID: UUID(), startedAt: startedAt, finishedAt: finishedAt
        )
        try tcpRecord.validate()
        try check(tcpRecord.status == .succeeded && tcpRecord.executedLayers == [.tcp] &&
                  tcpRecord.actualTarget == "192.0.2.21" && tcpRecord.addressFamily == .ipv4,
                  "TCP completion records the actual peer and address family")

        let states: [(DiagnosticRunStatus, FieldRetestStatus)] = [
            (.failed, .failed), (.interrupted, .interrupted), (.cancelled, .cancelled),
            (.timedOut, .timedOut), (.permissionDenied, .permissionDenied), (.unreachable, .unreachable)
        ]
        for (input, expected) in states {
            let result = DiagnosticExecutionResult(status: input, summary: "Fixture status")
            let record = FieldRetestExecutor.completedRecord(
                request: tcpRequest, result: result, runID: UUID(), startedAt: startedAt, finishedAt: finishedAt
            )
            try record.validate()
            try check(record.status == expected, "completed retest maps \(input) to \(expected)")
        }
    }

    private static func projectPersistence() throws {
        let record = makeRecord()
        try record.validate()
        var project = FieldProject()
        try check(project.attachRetestRun(record) == .attached,
                  "a completed authorized retest can be explicitly attached")
        try check(project.attachRetestRun(record) == .duplicate,
                  "a retest record cannot be attached twice")
        let reopened = try FieldProject.decode(project.encoded())
        try check(reopened == project && reopened.retestRuns == [record],
                  "attached retest requests and results survive project save and reopen")

        let summary = reopened.report(includeDetails: false, translate: { $0 })
        let details = reopened.report(includeDetails: true, translate: { $0 })
        for privateValue in ["CHG-1042", "Engineer", "service.example", "192.0.2.15", "VPN off / Wi-Fi corp", "Fixture observation"] {
            try check(!summary.contains(privateValue), "default retest summary omits \(privateValue)")
            try check(details.contains(privateValue), "detailed retest report includes \(privateValue)")
        }
        try check(summary.contains("Attached retest results: 1") && details.contains("Connection succeeded"),
                  "reports show only the retest count by default and include its outcome in details")

        let invalidTime = makeRecord(authorization: FieldRetestAuthorization(
            reference: "CHG-1042", confirmedBy: "Engineer", confirmedAt: now.addingTimeInterval(300),
            windowStart: now.addingTimeInterval(-60), windowEnd: now.addingTimeInterval(60), confirmed: true
        ))
        try check(invalidTime.validateStoredForChecks() == false,
                  "a persisted result cannot claim authorization after the approved window")

        var full = FieldProject()
        for _ in 0..<FieldProject.maximumRetestRuns {
            try check(full.attachRetestRun(makeRecord(id: UUID(), requestID: UUID())) == .attached,
                      "retest records can be retained up to the document limit")
        }
        try check(full.attachRetestRun(makeRecord(id: UUID(), requestID: UUID())) == .limitReached,
                  "the project rejects retest records beyond its explicit limit")
    }

    private static func baselineReferences() throws {
        var project = FieldProject()
        var draft = project.acceptanceDraft
        draft.planVersion = "Plan A"
        let requirement = FieldRequirement(title: "Service available")
        let point = FieldMeasurementPoint(title: "Core switch")
        var item = FieldAcceptanceItem(kind: .acceptance)
        item.requirementID = requirement.id
        item.pointID = point.id
        item.criterion = "TCP/443 reachable"
        item.conditions = "Approved maintenance window"
        draft.requirements = [requirement]
        draft.points = [point]
        draft.items = [item]
        project.acceptanceDraft = draft
        try project.createAcceptanceRevision()
        let revision = project.acceptanceRevisions[0]

        let linked = makeRecord(request: validRequest(
            baselineRevisionID: revision.id, acceptanceItemID: item.id
        ))
        try check(project.attachRetestRun(linked) == .attached,
                  "a retest may cite an existing handoff row")

        let danglingEvidence = makeRecord(request: validRequest(
            baselineRevisionID: revision.id, acceptanceItemID: item.id, baselineEvidenceID: UUID()
        ))
        try check(project.attachRetestRun(danglingEvidence) == .invalidBaseline,
                  "a retest cannot cite evidence missing from its selected handoff row")
    }

    private static func validRequest(
        id: UUID = UUID(), target: String = "service.example", method: FieldRetestMethod = .systemDNS,
        recordType: DNSRecordType = .a, server: String? = nil, serverPort: UInt16 = 53, port: Int? = nil,
        baselineRevisionID: UUID? = nil, acceptanceItemID: UUID? = nil, baselineEvidenceID: UUID? = nil
    ) -> FieldRetestRequest {
        FieldRetestRequest(
            id: id, check: .retest, acceptanceItemID: acceptanceItemID,
            baselineRevisionID: baselineRevisionID, baselineEvidenceID: baselineEvidenceID,
            target: target, method: method, dnsRecordType: recordType, dnsServer: server,
            dnsServerPort: serverPort, tcpPort: port,
            authorization: FieldRetestAuthorization(
                reference: "CHG-1042", confirmedBy: "Engineer", confirmedAt: now.addingTimeInterval(-5),
                windowStart: now.addingTimeInterval(-60), windowEnd: now.addingTimeInterval(60), confirmed: true
            ), networkContext: "VPN off / Wi-Fi corp", baselineNetworkContext: "VPN off / Wi-Fi corp",
            baselineAddressFamily: .ipv4
        )
    }

    private static func makeRecord(
        id: UUID = UUID(), requestID: UUID = UUID(), request: FieldRetestRequest? = nil,
        authorization: FieldRetestAuthorization? = nil
    ) -> FieldRetestRecord {
        var savedRequest = request ?? validRequest(id: requestID)
        if let authorization { savedRequest.authorization = authorization }
        return FieldRetestRecord(
            id: id, request: savedRequest, status: .succeeded, startedAt: now,
            finishedAt: now.addingTimeInterval(0.2), actualTarget: "192.0.2.15",
            addressFamily: .ipv4, dnsMode: .system, resolver: "192.0.2.53",
            observedPath: "Fixture observation", summary: "Connection succeeded",
            executedLayers: [.dns]
        )
    }

    private static func expect(_ expected: FieldRetestValidationError, _ request: FieldRetestRequest) throws {
        do {
            try request.validate(now: now)
            throw CheckFailure(description: "Expected retest validation error: \(expected)")
        } catch let error as FieldRetestValidationError {
            try check(error == expected, "retest validation reports \(expected)")
        }
    }
}

private extension FieldRetestRecord {
    func validateStoredForChecks() -> Bool {
        (try? validate()) != nil
    }
}
