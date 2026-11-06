import SwiftUI
import NMCore

public struct ScannerView: View {
    public enum Mode: String, CaseIterable, Identifiable {
        case ipScanner, portScanner, ping
        public var id: String { rawValue }
        var title: String {
            switch self { case .ipScanner: return "IP Scanner"; case .portScanner: return "Port Scanner"; case .ping: return "Ping Monitor" }
        }
    }

    @Environment(\.palette) private var palette
    @NMStateCompat private var mode: Mode
    @NMStateCompat private var host = "127.0.0.1"
    @NMStateCompat private var range = "127.0.0.1"
    @NMStateCompat private var portsText = "22,80,443,3389,5900"
    @NMStateCompat private var timeoutText = "1.5"
    @NMStateCompat private var attemptsText = "1"
    @NMStateCompat private var concurrencyText = "128"
    @NMStateCompat private var pingCountText = "10"
    @NMStateCompat private var intervalText = "0.8"
    @NMStateCompat private var showClosed = true
    @NMStateCompat private var results: [ScanRow] = []
    @NMStateCompat private var isRunning = false
    @NMStateCompat private var message = ""
    @NMStateCompat private var completedTargets = 0
    @NMStateCompat private var totalTargets = 0
    @NMStateCompat private var scanTask: Task<Void, Never>?
    @NMStateCompat private var scanCancellation: DiagnosticCancellation?
    @NMStateCompat private var showLargeIPScanConfirmation = false
    @NMStateCompat private var pendingIPScanRange = ""
    @NMStateCompat private var pendingIPScanCount = 0

    public init(mode: Mode = .portScanner, initialHost: String? = nil) {
        _mode = NMStateCompat(wrappedValue: mode)
        _host = NMStateCompat(wrappedValue: initialHost ?? "127.0.0.1")
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(t(mode.title)).font(.largeTitle.bold())
                Spacer()
                Picker(t("Tool"), selection: $mode) {
                    ForEach(Mode.allCases) { Text(t($0.title)).tag($0) }
                }
                .pickerStyle(.menu)
                .disabled(isRunning)
            }
            GroupBox(t("Scan parameters")) {
                HStack(spacing: 12) {
                    TextField(t("Host or range"), text: mode == .ipScanner ? $range : $host)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isRunning)
                        .accessibilityIdentifier(mode == .ipScanner ? "ipScannerRange" : "scannerHost")
                    if mode == .portScanner {
                        TextField(t("Ports"), text: $portsText).textFieldStyle(.roundedBorder).frame(width: 230).disabled(isRunning)
                    }
                    TextField(t("Timeout (s)"), text: $timeoutText).textFieldStyle(.roundedBorder).frame(width: 100).disabled(isRunning)
                    if mode == .ipScanner {
                        TextField(t("Attempts"), text: $attemptsText).textFieldStyle(.roundedBorder).frame(width: 90).disabled(isRunning)
                    }
                    if mode == .portScanner {
                        TextField(t("Concurrency"), text: $concurrencyText).textFieldStyle(.roundedBorder).frame(width: 110).disabled(isRunning)
                        Toggle(t("Show closed"), isOn: $showClosed).toggleStyle(.checkbox).disabled(isRunning)
                    }
                    if mode == .ping {
                        TextField(t("Count"), text: $pingCountText).textFieldStyle(.roundedBorder).frame(width: 75).disabled(isRunning)
                        TextField(t("Interval (s)"), text: $intervalText).textFieldStyle(.roundedBorder).frame(width: 100).disabled(isRunning)
                    }
                    Button(isRunning ? t("Running…") : t("Start")) { start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isRunning || (mode == .ipScanner && !canStartIPScan))
                        .accessibilityIdentifier(mode == .ipScanner ? "startIPScan" : "startScannerRun")
                    if isRunning {
                        Button(t("Stop")) { cancelCurrentScan() }
                            .buttonStyle(.bordered)
                            .disabled(scanCancellation?.isCancelled == true)
                            .accessibilityIdentifier("stopScannerRun")
                    }
                    Button(t("Clear")) { results.removeAll(); message = "" }
                        .buttonStyle(.bordered)
                        .disabled(isRunning)
                }
            }
            if mode == .ipScanner {
                if let preview = ipScanPreview {
                    Label(tf("%d targets: %@ to %@", preview.count, preview.firstTarget, preview.lastTarget), systemImage: "scope")
                        .font(.callout.monospaced())
                        .foregroundStyle(palette.textSecondary)
                        .accessibilityIdentifier("ipScanPreview")
                    if preview.count > HostRangeParser.maximumHosts {
                        Text(tf("The range contains %d addresses, exceeding the scan limit of %d.", preview.count, HostRangeParser.maximumHosts))
                            .font(.caption).foregroundStyle(palette.warning)
                    }
                } else if let error = ipScanPreviewError {
                    Text(error).font(.caption).foregroundStyle(palette.danger)
                }
            }
            if mode == .ipScanner, totalTargets > 0 {
                HStack(spacing: 10) {
                    ProgressView(value: Double(completedTargets), total: Double(totalTargets))
                    Text(tf("%d of %d targets", completedTargets, totalTargets))
                        .font(.caption.monospaced()).foregroundStyle(palette.textSecondary)
                }
                .accessibilityIdentifier("ipScanProgress")
            }
            if !message.isEmpty { Text(message).foregroundStyle(palette.textSecondary) }
            Table(results) {
                TableColumn(t("Host")) { Text($0.host).font(.body.monospaced()) }
                TableColumn(t("Port")) { Text($0.port.map(String.init) ?? "—") }
                TableColumn(t("Status")) { Text($0.status).foregroundStyle($0.success ? palette.success : palette.danger) }
                TableColumn(t("Latency")) { Text(Fmt.ms($0.latency)) }
                TableColumn(t("Details")) { Text($0.details).foregroundStyle(palette.textSecondary) }
            }
            .frame(minHeight: 380)
        }
        .padding(28)
        .background(palette.background)
        .onDisappear { cancelCurrentScan() }
        .confirmationDialog(t("Confirm large network scan"), isPresented: $showLargeIPScanConfirmation, titleVisibility: .visible) {
            Button(tf("Scan %d addresses", pendingIPScanCount)) {
                startIPScan(expression: pendingIPScanRange)
            }
            Button(t("Cancel"), role: .cancel) { pendingIPScanRange = "" }
        } message: {
            Text(tf("Range %@ contains %d addresses. Continue?", pendingIPScanRange, pendingIPScanCount))
        }
    }

    private var ipScanPreview: HostRangePreview? {
        try? HostRangeParser.preview(range)
    }

    private var ipScanPreviewError: String? {
        guard !range.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        do {
            _ = try HostRangeParser.preview(range)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private var canStartIPScan: Bool {
        guard let preview = ipScanPreview else { return false }
        return preview.count <= HostRangeParser.maximumHosts
    }

    private func start() {
        guard !isRunning else { return }
        switch mode {
        case .portScanner: startPortScan()
        case .ipScanner: requestIPScan()
        case .ping: startPing()
        }
    }

    private func beginScan(total: Int) -> DiagnosticCancellation {
        results.removeAll()
        completedTargets = 0
        totalTargets = total
        isRunning = true
        message = t("Running…")
        let cancellation = DiagnosticCancellation()
        scanCancellation = cancellation
        return cancellation
    }

    private func cancelCurrentScan() {
        scanCancellation?.cancel()
        scanTask?.cancel()
        if isRunning { message = t("Stopping…") }
    }

    private func finishScan(_ finalMessage: String) {
        isRunning = false
        scanTask = nil
        scanCancellation = nil
        message = finalMessage
    }

    private func startPortScan() {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let ports = TCPProbe.parsePorts(portsText)
        guard !target.isEmpty, !ports.isEmpty else { message = t("Invalid input"); return }
        let timeout = max(0.1, Double(timeoutText) ?? 1.5)
        let concurrency = max(1, Int(concurrencyText) ?? 128)
        let includeClosed = showClosed
        let cancellation = beginScan(total: ports.count)
        scanTask = Task {
            let scanned = await TCPProbe.scan(host: target, ports: ports, timeout: timeout,
                                              concurrency: concurrency, cancellation: cancellation)
            results = scanned.filter { includeClosed || $0.status == .open }.map {
                ScanRow(host: target, port: $0.port, status: $0.status.rawValue,
                        latency: $0.latency, details: $0.message ?? "", success: $0.status == .open)
            }
            completedTargets = scanned.count
            let wasCancelled = cancellation.isCancelled || Task.isCancelled
            finishScan(wasCancelled
                ? tf("Stopped after %d of %d targets.", completedTargets, totalTargets)
                : tf("Completed: %d port(s)", scanned.count))
        }
    }

    private func requestIPScan() {
        let expression = range
        guard let preview = try? HostRangeParser.preview(expression) else {
            message = ipScanPreviewError ?? t("Invalid input")
            return
        }
        guard preview.count <= HostRangeParser.maximumHosts else {
            message = tf("The range contains %d addresses, exceeding the scan limit of %d.", preview.count, HostRangeParser.maximumHosts)
            return
        }
        message = ""
        if preview.count > HostRangeParser.largeScanConfirmationThreshold {
            pendingIPScanRange = expression
            pendingIPScanCount = preview.count
            showLargeIPScanConfirmation = true
        } else {
            startIPScan(expression: expression)
        }
    }

    private func startIPScan(expression: String) {
        guard !isRunning else { return }
        do {
            let hosts = try HostRangeParser.parse(expression)
            guard hosts.count <= HostRangeParser.maximumHosts else {
                message = tf("The range contains %d addresses, exceeding the scan limit of %d.", hosts.count, HostRangeParser.maximumHosts)
                return
            }
            let timeout = max(0.1, Double(timeoutText) ?? 1.2)
            let attempts = max(1, Int(attemptsText) ?? 1)
            let cancellation = beginScan(total: hosts.count)
            let concurrency = min(32, hosts.count)
            scanTask = Task {
                var nextIndex = 0
                await withTaskGroup(of: ScanRow?.self) { group in
                    while nextIndex < concurrency, !cancellation.isCancelled {
                        let target = hosts[nextIndex]
                        group.addTask { await Self.scanIPTarget(target, timeout: timeout, attempts: attempts, cancellation: cancellation) }
                        nextIndex += 1
                    }
                    while let row = await group.next() {
                        if Task.isCancelled || cancellation.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let row { results.append(row) }
                        completedTargets += 1
                        if nextIndex < hosts.count {
                            let target = hosts[nextIndex]
                            group.addTask { await Self.scanIPTarget(target, timeout: timeout, attempts: attempts, cancellation: cancellation) }
                            nextIndex += 1
                        }
                    }
                }
                let wasCancelled = cancellation.isCancelled || Task.isCancelled
                finishScan(wasCancelled
                    ? tf("Stopped after %d of %d targets.", completedTargets, totalTargets)
                    : tf("Completed: %d host(s)", hosts.count))
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private nonisolated static func scanIPTarget(_ target: String, timeout: TimeInterval, attempts: Int,
                                                 cancellation: DiagnosticCancellation) async -> ScanRow? {
        var reply: ICMPReply?
        for _ in 0..<attempts {
            guard !Task.isCancelled, !cancellation.isCancelled else { return nil }
            let attempt = await Task.detached(priority: .utility) { () -> ICMPReply? in
                guard !cancellation.isCancelled,
                      let pinger = try? ICMPPinger(host: target, timeout: timeout, cancellation: cancellation) else { return nil }
                return pinger.ping()
            }.value
            guard !Task.isCancelled, !cancellation.isCancelled else { return nil }
            reply = attempt
            if attempt?.outcome.isSuccess == true { break }
        }
        guard !Task.isCancelled, !cancellation.isCancelled else { return nil }
        return ScanRow(host: target, port: nil, status: reply?.outcome.displayName ?? t("Error"),
                       latency: reply?.rtt, details: reply?.source ?? "", success: reply?.outcome.isSuccess == true)
    }

    private func startPing() {
        let target = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { message = t("Invalid input"); return }
        let count = max(1, Int(pingCountText) ?? 10)
        let interval = max(0.1, Double(intervalText) ?? 0.8)
        let timeout = max(0.1, Double(timeoutText) ?? 2.0)
        let cancellation = beginScan(total: count)
        scanTask = Task {
            for _ in 0..<count {
                guard !Task.isCancelled, !cancellation.isCancelled else { break }
                let reply = await Task.detached(priority: .utility) { () -> ICMPReply? in
                    guard !cancellation.isCancelled,
                          let pinger = try? ICMPPinger(host: target, timeout: timeout, cancellation: cancellation) else { return nil }
                    return pinger.ping()
                }.value
                guard !Task.isCancelled, !cancellation.isCancelled else { break }
                let success = reply?.outcome.isSuccess == true
                results.append(ScanRow(host: target, port: nil, status: reply?.outcome.displayName ?? t("Error"),
                                       latency: reply?.rtt, details: reply?.source ?? "", success: success))
                completedTargets += 1
                do {
                    try await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                } catch {
                    break
                }
            }
            let wasCancelled = cancellation.isCancelled || Task.isCancelled
            finishScan(wasCancelled
                ? tf("Stopped after %d of %d targets.", completedTargets, totalTargets)
                : t("Completed"))
        }
    }
}

private struct ScanRow: Identifiable, Sendable {
    let id = UUID()
    let host: String
    let port: Int?
    let status: String
    let latency: TimeInterval?
    let details: String
    let success: Bool
}
