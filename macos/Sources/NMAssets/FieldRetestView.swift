import NMCore
import SwiftUI

struct FieldRetestView: View {
    @Binding var project: FieldProject
    let preparation: FieldRetestPreparation?
    @ObservedObject private var assets = AssetStore.shared
    @NMStateCompat private var request = FieldRetestRequest()
    @NMStateCompat private var selectedItemID: UUID?
    @NMStateCompat private var selectedEvidenceID: UUID?
    @NMStateCompat private var selectedMethod: FieldRetestMethod?
    @NMStateCompat private var pendingRecord: FieldRetestRecord?
    @NMStateCompat private var isRunning = false
    @NMStateCompat private var runTask: Task<Void, Never>?
    @NMStateCompat private var errorMessage = ""

    init(project: Binding<FieldProject>, preparation: FieldRetestPreparation? = nil) {
        _project = project
        self.preparation = preparation
    }

    private var selectedBaselineRevision: FieldAcceptanceRevision? {
        project.acceptanceRevisions.first { $0.id == request.baselineRevisionID }
    }

    private var selectedBaselineItem: FieldAcceptanceSnapshotItem? {
        selectedBaselineRevision?.items.first { $0.id == selectedItemID }
    }

    private var selectedBaselineEvidence: FieldProjectDiagnosticEvidence? {
        selectedBaselineItem?.diagnostics.first { $0.id == selectedEvidenceID }
    }

    var body: some View {
        GroupBox(t("Authorized single-service retest")) {
            VStack(alignment: .leading, spacing: 12) {
                if let preparation {
                    LabeledContent(t("Prepared from incident"), value: preparation.incidentTitle)
                    Text(t("A completed retest must be linked to the incident timeline separately."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                baselineFields
                if selectedBaselineRevision == nil {
                    Text(t("Select a handoff revision before preparing a retest."))
                        .foregroundStyle(.secondary)
                }

                TextField(t("Target host or IP address"), text: $request.target)
                    .accessibilityIdentifier("fieldRetestTarget")

                Picker(t("Method"), selection: $selectedMethod) {
                    Text(t("Choose a method")).tag(nil as FieldRetestMethod?)
                    ForEach(FieldRetestMethod.allCases, id: \.self) { method in
                        Text(t(method.title)).tag(Optional(method))
                    }
                }
                .accessibilityIdentifier("fieldRetestMethod")
                .onChange(of: selectedMethod) { _, method in
                    guard let method else { return }
                    updateMethod(method)
                }
                .onChange(of: request.target) { _, _ in
                    request.authorization.confirmed = false
                }

                if selectedMethod != nil {
                    methodFields
                }

                TextField(t("Current network conditions"), text: $request.networkContext, axis: .vertical)
                    .lineLimit(1...3)
                    .onChange(of: request.networkContext) { _, _ in request.authorization.confirmed = false }
                TextField(t("Approved baseline network conditions"), text: $request.baselineNetworkContext, axis: .vertical)
                    .lineLimit(1...3)

                Divider()

                TextField(t("Change or authorization reference"), text: $request.authorization.reference)
                    .onChange(of: request.authorization.reference) { _, _ in request.authorization.confirmed = false }
                TextField(t("Confirmed by"), text: $request.authorization.confirmedBy)
                    .onChange(of: request.authorization.confirmedBy) { _, _ in request.authorization.confirmed = false }
                DatePicker(t("Window start"), selection: $request.authorization.windowStart,
                           displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: request.authorization.windowStart) { _, _ in request.authorization.confirmed = false }
                DatePicker(t("Window end"), selection: $request.authorization.windowEnd,
                           displayedComponents: [.date, .hourAndMinute])
                    .onChange(of: request.authorization.windowEnd) { _, _ in request.authorization.confirmed = false }
                Toggle(t("I confirm this target and method are authorized for this window."),
                       isOn: $request.authorization.confirmed)
                    .onChange(of: request.authorization.confirmed) { _, confirmed in
                        if confirmed { request.authorization.confirmedAt = Date() }
                    }
                    .accessibilityIdentifier("fieldRetestAuthorizationConfirmed")

                HStack {
                    if isRunning {
                        ProgressView().controlSize(.small)
                        Text(t("Retest in progress"))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button(t("Cancel retest"), systemImage: "stop.circle") {
                            runTask?.cancel()
                        }
                    } else {
                        Spacer()
                        Button(t("Start retest"), systemImage: "play.fill") { startRetest() }
                            .buttonStyle(.borderedProminent)
                            .disabled(assets.isLoadingWorkspace || selectedBaselineRevision == nil ||
                                      selectedBaselineItem == nil || selectedMethod == nil)
                            .accessibilityIdentifier("fieldStartRetest")
                    }
                }

                if let pendingRecord {
                    resultView(pendingRecord)
                }

                if !project.retestRuns.isEmpty {
                    Divider()
                    Text(t("Attached retest results"))
                        .font(.headline)
                    ForEach(Array(project.retestRuns.reversed())) { record in
                        savedRecordView(record)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
        .onAppear {
            if let preparation {
                prepareRetest(preparation)
                return
            }
            guard request.baselineRevisionID == nil else { return }
            request.baselineRevisionID = project.maintenanceRevisionID
        }
        .onDisappear {
            runTask?.cancel()
            request.authorization.confirmed = false
        }
        .onChange(of: preparation) { _, preparation in
            guard let preparation else { return }
            prepareRetest(preparation)
        }
        .onChange(of: project.maintenanceRevisionID) { previousID, revisionID in
            guard preparation == nil else { return }
            guard request.baselineRevisionID == previousID else { return }
            request.baselineRevisionID = revisionID
        }
        .onChange(of: request.baselineRevisionID) { _, _ in
            resetBaselineSelection()
        }
        .onChange(of: selectedItemID) { _, id in selectBaselineItem(id) }
        .onChange(of: selectedEvidenceID) { _, id in selectBaselineEvidence(id) }
        .fieldProjectError($errorMessage)
    }

    private func resetBaselineSelection() {
            selectedItemID = nil
            selectedEvidenceID = nil
            request.acceptanceItemID = nil
            request.baselineEvidenceID = nil
            request.baselineNetworkContext = ""
            request.baselineAddressFamily = nil
            request.baselineTarget = nil
            request.baselineMethod = nil
    }

    private var baselineFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(t("Handoff revision"), selection: $request.baselineRevisionID) {
                Text(t("Not selected")).tag(nil as UUID?)
                ForEach(project.acceptanceRevisions) { revision in
                    Text(FieldAcceptanceRevisionView.title(for: revision)).tag(Optional(revision.id))
                }
            }
            .disabled(preparation?.revisionID != nil)
            .accessibilityIdentifier("fieldRetestBaselineRevision")
            if preparation?.revisionID != nil {
                Text(t("The incident's handoff revision is fixed for this retest."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker(t("Handoff row"), selection: $selectedItemID) {
                Text(t("Not selected")).tag(nil as UUID?)
                ForEach(selectedBaselineRevision?.items ?? []) { row in
                    Text("\(t(row.item.kind.title)) · \(row.requirement) · \(row.point)")
                        .tag(Optional(row.id))
                }
            }
            .accessibilityIdentifier("fieldRetestBaselineRow")

            if let row = selectedBaselineItem, !row.diagnostics.isEmpty {
                Picker(t("Baseline diagnostic evidence"), selection: $selectedEvidenceID) {
                    Text(t("No specific evidence")).tag(nil as UUID?)
                    ForEach(row.diagnostics) { evidence in
                        Text("\(evidence.kind) · \(evidence.target)").tag(Optional(evidence.id))
                    }
                }
                .accessibilityIdentifier("fieldRetestBaselineEvidence")
            }

            TextField(t("Baseline target"), text: baselineTarget)
            Picker(t("Baseline method"), selection: baselineMethod) {
                Text(t("Not selected")).tag(nil as FieldRetestMethod?)
                ForEach(FieldRetestMethod.allCases, id: \.self) { method in
                    Text(t(method.title)).tag(Optional(method))
                }
            }
        }
    }

    @ViewBuilder
    private var methodFields: some View {
        switch request.method {
        case .systemDNS:
            dnsRecordPicker
        case .specifiedDNS:
            dnsRecordPicker
            TextField(t("DNS server"), text: Binding(
                get: { request.dnsServer ?? "" },
                set: { request.dnsServer = $0.isEmpty ? nil : $0 }
            ))
            .onChange(of: request.dnsServer) { _, _ in request.authorization.confirmed = false }
            TextField(t("DNS server port"), value: dnsPort, format: .number)
                .onChange(of: request.dnsServerPort) { _, _ in request.authorization.confirmed = false }
        case .tcp, .tls:
            TextField(t("TCP port"), value: tcpPort, format: .number)
                .onChange(of: request.tcpPort) { _, _ in request.authorization.confirmed = false }
        case .http:
            Picker(t("HTTP scheme"), selection: Binding(get: { request.httpScheme ?? "https" }, set: {
                request.httpScheme = $0
                request.tcpPort = $0 == "http" ? 80 : 443
                request.authorization.confirmed = false
            })) {
                Text("HTTPS").tag("https")
                Text("HTTP").tag("http")
            }
            TextField(t("TCP port"), value: tcpPort, format: .number)
                .onChange(of: request.tcpPort) { _, _ in request.authorization.confirmed = false }
            TextField(t("HTTP absolute path"), text: Binding(get: { request.httpPath ?? "/" }, set: { request.httpPath = $0 }))
                .onChange(of: request.httpPath) { _, _ in request.authorization.confirmed = false }
                .accessibilityIdentifier("fieldRetestHTTPPath")
            Text(t("HEAD only; no credentials or cookies. Redirects are not followed. A 2xx response passes this check."))
                .font(.caption).foregroundStyle(.secondary)
        case .directTCP:
            TextField(t("TCP port"), value: tcpPort, format: .number)
                .onChange(of: request.tcpPort) { _, _ in request.authorization.confirmed = false }
        }
        if request.method == .tls || request.method == .http {
            Text(t("TLS and HTTPS use system trust. Total deadline: five seconds. Network route and interface are not verified."))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dnsRecordPicker: some View {
        Picker(t("DNS record type"), selection: $request.dnsRecordType) {
            ForEach([DNSRecordType.a, .aaaa], id: \.self) { type in
                Text(type.displayName).tag(type)
            }
        }
        .onChange(of: request.dnsRecordType) { _, _ in request.authorization.confirmed = false }
    }

    private var dnsPort: Binding<Int> {
        Binding(
            get: { Int(request.dnsServerPort) },
            set: { request.dnsServerPort = (0...65_535).contains($0) ? UInt16($0) : 0 }
        )
    }

    private var tcpPort: Binding<Int> {
        Binding(
            get: { request.tcpPort ?? 443 },
            set: { request.tcpPort = $0 }
        )
    }

    private var baselineTarget: Binding<String> {
        Binding(
            get: { request.baselineTarget ?? "" },
            set: { request.baselineTarget = $0.isEmpty ? nil : $0 }
        )
    }

    private var baselineMethod: Binding<FieldRetestMethod?> {
        Binding(
            get: { request.baselineMethod },
            set: { request.baselineMethod = $0 }
        )
    }

    private func updateMethod(_ method: FieldRetestMethod) {
        request.authorization.confirmed = false
        var updated = request
        updated.selectMethod(method)
        request = updated
    }

    private func prepareRetest(_ preparation: FieldRetestPreparation) {
        runTask?.cancel()
        request.prepare(for: preparation)
        selectedItemID = nil
        selectedEvidenceID = nil
        selectedMethod = nil
        pendingRecord = nil
        errorMessage = ""
    }

    private func selectBaselineItem(_ id: UUID?) {
        request.authorization.confirmed = false
        guard let id, let row = selectedBaselineRevision?.items.first(where: { $0.id == id }) else {
            request.acceptanceItemID = nil
            request.baselineEvidenceID = nil
            request.baselineNetworkContext = ""
            request.baselineAddressFamily = nil
            request.baselineTarget = nil
            request.baselineMethod = nil
            return
        }
        selectedEvidenceID = row.diagnostics.first?.id
        request.acceptanceItemID = row.id
        request.baselineEvidenceID = row.diagnostics.first?.id
        let evidence = row.diagnostics.first
        request.baselineNetworkContext = evidence.map {
            $0.networkContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? row.item.conditions : $0.networkContext
        } ?? row.item.conditions
        request.baselineAddressFamily = row.diagnostics.first?.addressFamily
        request.baselineTarget = row.diagnostics.first?.target
        request.baselineMethod = nil
        if preparation == nil, let target = row.diagnostics.first?.target {
            request.target = target
        }
        if request.target.isEmpty, let target = row.diagnostics.first?.target {
            request.target = target
        }
    }

    private func selectBaselineEvidence(_ id: UUID?) {
        request.authorization.confirmed = false
        guard let evidence = selectedBaselineItem?.diagnostics.first(where: { $0.id == id }) else {
            request.baselineEvidenceID = nil
            request.baselineTarget = nil
            request.baselineMethod = nil
            request.baselineAddressFamily = nil
            request.baselineNetworkContext = selectedBaselineItem?.item.conditions ?? ""
            return
        }
        request.baselineEvidenceID = evidence.id
        request.baselineAddressFamily = evidence.addressFamily
        request.baselineTarget = evidence.target
        request.baselineMethod = nil
        request.baselineNetworkContext = evidence.networkContext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (selectedBaselineItem?.item.conditions ?? "") : evidence.networkContext
        if preparation == nil || request.target.isEmpty {
            request.target = evidence.target
        }
    }

    private func startRetest() {
        guard selectedMethod != nil, selectedBaselineItem != nil else { return }
        request.check = .retest
        request.baselineRevisionID = selectedBaselineRevision?.id
        request.acceptanceItemID = selectedBaselineItem?.id
        request.baselineEvidenceID = selectedBaselineEvidence?.id
        let submittedRequest = request
        errorMessage = ""
        pendingRecord = nil
        runTask = ProcessRuntime.startDiagnosticTask(DiagnosticCancellation()) {
            defer {
                isRunning = false
                runTask = nil
            }
            do {
                let record = try await FieldRetestExecutor.run(submittedRequest, store: assets)
                guard request.id == submittedRequest.id else { return }
                pendingRecord = record
            } catch {
                guard request.id == submittedRequest.id else { return }
                errorMessage = error.localizedDescription
            }
        }
        isRunning = runTask != nil
    }

    private func resultView(_ record: FieldRetestRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t(record.status.title), systemImage: record.status == .succeeded ? "checkmark.circle" : "exclamationmark.circle")
                .font(.headline)
            LabeledContent(t("Target"), value: record.actualTarget)
            LabeledContent(t("Address family"), value: t(record.addressFamily.title))
            LabeledContent(t("Compared with baseline"), value: t(record.comparisonState.title))
            Text(record.summary)
                .textSelection(.enabled)
            if !record.detail.isEmpty { Text(record.detail).textSelection(.enabled).foregroundStyle(.secondary) }
            if let reason = record.notComparableReason { Text(reason).foregroundStyle(.secondary) }
            Button(t("Attach selected result"), systemImage: "paperclip") {
                switch project.attachRetestRun(record) {
                case .attached:
                    pendingRecord = nil
                case .duplicate:
                    errorMessage = t("This retest result is already attached.")
                case .limitReached:
                    errorMessage = t("This project has reached the retest result limit.")
                case .invalidRecord:
                    errorMessage = t("This retest result is invalid.")
                case .invalidBaseline:
                    errorMessage = t("The selected handoff baseline is no longer available.")
                case .documentLimit:
                    errorMessage = t("The field project exceeds the 512 KB limit.")
                }
            }
            .accessibilityIdentifier("fieldAttachRetestResult")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    private func savedRecordView(_ record: FieldRetestRecord) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                LabeledContent(t("Authorization reference"), value: record.request.authorization.reference)
                LabeledContent(t("Confirmed by"), value: record.request.authorization.confirmedBy)
                LabeledContent(t("Measured at"), value: Fmt.dateTime(record.startedAt))
                LabeledContent(t("Actual target"), value: record.actualTarget)
                LabeledContent(t("Address family"), value: t(record.addressFamily.title))
                LabeledContent(t("Observed path"), value: record.observedPath)
                LabeledContent(t("Current network conditions"), value: record.request.networkContext)
                LabeledContent(t("Compared with baseline"), value: t(record.comparisonState.title))
                Text(record.summary).textSelection(.enabled)
                if !record.detail.isEmpty { Text(record.detail).textSelection(.enabled) }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(t(record.request.method.title)) · \(record.request.normalizedTarget)")
                    Text("\(t(record.status.title)) · \(Fmt.dateTime(record.startedAt))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(t("Remove retest result"), systemImage: "trash") {
                    project.removeRetestRun(id: record.id)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help(t("Remove retest result"))
            }
        }
        .accessibilityIdentifier("fieldRetestRecord-\(record.id.uuidString)")
    }
}
