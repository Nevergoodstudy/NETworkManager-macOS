# T01 / T03 实施前置设计 / Implementation preparation

修订日期 / Updated: 2026-11-10

状态 / Status: 设计输入，尚未实现 / Design input; not implemented

源码基准 / Source baseline: [`08840c67995b`](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/08840c67995b5191a338561fc215c6bc15d32863)
跟踪议题 / Tracking: [T01 #14](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) · [T03 #16](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) · [总计划 #13](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/13)

This note turns the first P0 backlog items into reviewable engineering work. It records current code paths, proposed contracts, migration order and test evidence. It does not claim that the changes have been implemented or validated on physical devices.

## 决策摘要 / Decisions to review

1. **TCP 探测保留证据，不把所有失败映射为 `closed`。** `refused` can support a closed-port interpretation for the attempted address; timeout should remain `noResponse` or `filtered/unknown` according to the product wording. Resolver failure, cancellation and local policy errors remain separate outcomes.
2. **权限拒绝只在平台给出明确证据时标记。** POSIX `EACCES`/`EPERM` can be preserved as permission-related socket failures. Do not infer Local Network privacy denial from a generic timeout. Where the UI needs to identify macOS Local Network denial, evaluate `Network.framework` path state (`NWConnection.State.waiting` and `NWPath.unsatisfiedReason.localNetworkDenied`) as a bounded adapter or diagnostic; do not add a second transport implementation without a demonstrated need. Apple documents this path-state signal for TCP and notes that the alert can initially deny an operation while the user decides.
3. **T01 should establish the shared failure vocabulary before T03.** T03 may wrap outcomes in Job lifecycle states, but it must retain the underlying diagnostic reason and stage.
4. **Job budgets are per process in this stage.** GUI and each MCP process have independent runtime instances. A machine-wide shared quota would require a separately reviewed broker and is outside T03.

The Local Network behavior described above is based on Apple's current [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). The note says local-network privacy applies to outgoing TCP to local addresses on macOS 15 and later, covers BSD sockets as well as Network.framework, and gives `NWConnection` path state as a way to detect `localNetworkDenied`. Test this behavior on signed app builds and real macOS accounts; command-line and ad-hoc test contexts do not represent the shipped app identity reliably.

## 当前代码触点 / Current code touchpoints

| Area | Current behavior to account for | Proposed scope |
|---|---|---|
| `macos/Sources/NMCore/Net/TCPProbe.swift` | `connect` returns optional latency; resolver errors and socket errors can collapse to `nil`; `probe` maps the remaining `nil` to `.closed`. `getsockopt(SO_ERROR)` is read but its non-zero value is discarded. | Introduce a typed internal connect outcome carrying stage, errno/SO_ERROR and elapsed time; derive display status from that outcome. Keep scan ordering and concurrency behavior stable while migrating callers. |
| `macos/Sources/NMCore/Net/SocketAddressResolver.swift` | Resolver already distinguishes cancelled, timed out, service error and no addresses. | Preserve these cases when adapting TCP; do not turn them into a port-state assertion. |
| `macos/Sources/NMCore/DiagnosticService.swift` | TCP `.closed`, `.filtered` and `.openFiltered` all become generic `.failed`; the shared `DiagnosticRunStatus` already has `permissionDenied`, `timedOut`, `unreachable` and `cancelled`. | Map typed results once in the service. Keep protocol-specific reason in structured detail so asset history and MCP do not need to parse localized strings. |
| `macos/Sources/NMCore/Shell.swift` | `CommandResult` has exit code, stdout, stderr, timeout and cancellation, but no launch-failure category or output-byte cap. Async `run` drains both pipes. | T03 defines the bounded adapter contract first. Implementation should cap retained bytes while continuing to drain pipes, so a noisy child cannot block on a full pipe. |
| `macos/Sources/NMCore/Net/SystemNetwork.swift` | `lsof`, `arp` and `system_profiler` command failures can become an empty list. | Add throwing/result-returning APIs beside existing wrappers, then migrate each UI caller to show empty, denied, missing, unsupported and execution-error states distinctly. Avoid changing all inventory callers in the TCP patch. |
| `macos/Sources/NMScanners/ScannerView.swift` | TCP scanner consumes `PortProbeResult` and renders `PortStatus`. | Preserve a compatibility projection during T01; update labels/localization in the same PR as the typed status change. |
| `macos/Sources/NMCore/Assets.swift` and history views | Persisted status vocabulary is Codable; UI switches over it. | Prefer additive optional structured error metadata or a versioned status migration. Do not persist localized `localizedDescription` as the only error identity. |

## 建议契约草案 / Proposed contract draft

These names are a review starting point, not a requirement to add every type as a public API.

```swift
enum DiagnosticFailure: Sendable, Equatable {
    case refused(errno: Int32, address: String?)
    case timedOut(stage: DiagnosticStage)
    case unreachable(errno: Int32, address: String?)
    case permissionDenied(errno: Int32, context: PermissionContext)
    case cancelled
    case resolution(ResolutionFailure)
    case dependencyMissing(name: String)
    case unsupported(reason: String)
    case execution(errno: Int32?, message: String?)
}

enum TCPConnectOutcome: Sendable {
    case connected(latency: Duration, address: String)
    case failed(DiagnosticFailure)
}
```

Mapping rules:

- `connect == 0` and `SO_ERROR == 0` produce `connected`.
- Immediate `connect` errors and non-zero `SO_ERROR` are captured at the point they occur. `ECONNREFUSED` maps to `refused`; `ETIMEDOUT` to `timedOut`; routing errors such as `ENETUNREACH`/`EHOSTUNREACH` to `unreachable`; `EACCES`/`EPERM` to `permissionDenied`; all other values remain `execution` unless evidence supports a more specific classification.
- `poll` timeout, interrupted wait, cancellation and readiness error are not interchangeable. The wait helper contract should distinguish timeout/cancel/error instead of representing all three as `nil` before final implementation.
- With multiple resolved addresses, retain per-address attempts or a deterministic aggregate that preserves the most informative terminal error. Do not report a port `closed` merely because every address attempt failed for unrelated reasons.
- Keep `PortStatus` as a presentation grouping only if existing UI needs it. The structured reason is authoritative; labels such as “filtered” require an explicit evidence policy and should not be inferred from every timeout.
- Permission copy must explain what failed and where the user can check system settings only when the runtime result supports that explanation. A generic network timeout is not a permission diagnosis.

For T03, the initial `JobSpec` should include a stable ID, operation kind, validated target scope, absolute deadline, per-target timeout, maximum target count, concurrency, output-byte budget and cancellation handle. A Job emits bounded lifecycle/progress events and ends in exactly one terminal state. The runtime owns only work and child processes it started; cancellation uses graceful termination followed by a bounded force-kill, then drains/closes pipes and records cleanup results. Retries and address attempts consume the same absolute deadline.

Suggested lifecycle: `queued -> running -> (partial)* -> succeeded | failed | timedOut | cancelled`. A child-process launch failure is `dependencyMissing` only for a confirmed missing executable; other launch errors remain `execution`. Output truncation is explicit metadata, not silent clipping. GUI and MCP may render different copy, but consume the same typed outcome and stable field names.

## 实施顺序 / Implementation sequence

| Step | Change | Review gate |
|---|---|---|
| 0 | Approve failure vocabulary, status-to-UI wording, compatibility requirements for scan/MCP/history, and how per-address failures aggregate. | No persisted schema or public MCP shape changes without a compatibility note. |
| 1 | Refactor TCP connect internals to return a typed outcome and retain errno, `SO_ERROR`, stage, address and elapsed time. | Add deterministic socket-operation seam or narrow adapter so timeout, route, permission and cancellation paths do not depend on external networks. |
| 2 | Map typed outcome through `TCPProbe.probe`, scanner display and `DiagnosticService.runTCP`; preserve stable Codable data. | Existing open/refused behavior remains understandable; timeout and resolver failure no longer appear as closed. |
| 3 | Add a result-based system-command API for one inventory caller at a time; report command absence, launch failure, non-zero exit, timeout and valid empty output separately. | No broad silent change to every inventory screen; each migrated caller has a UI state and test. |
| 4 | Define `JobSpec`, `JobState`, bounded event/result contract and runtime ownership in T03; adapt one TCP diagnostic end-to-end first. | The same job result can be consumed by GUI and MCP without parsing human-readable strings. |
| 5 | Add bounded `ProcessAdapter` with pipe-drain, retained-byte cap, truncation marker and child cleanup; migrate traceroute as the first subprocess client. | Large stdout/stderr, slow consumer, cancellation and timeout tests pass without a pipe deadlock or orphan. |
| 6 | Expand runtime to selected scanner/MCP operations and record per-process budget scope. | Parallel, cancellation and disconnect checks pass; cross-process quotas remain explicitly out of scope. |

Keep the implementation PRs narrow: T01 TCP semantics first; separate SystemNetwork result migration if it expands beyond one caller; T03 runtime contract and one vertical slice; then subprocess adapter adoption. This makes review and rollback practical while keeping issue #16 dependent on the agreed T01 outcome model.

## 测试与验收矩阵 / Test and acceptance matrix

| Case | Harness | Expected evidence |
|---|---|---|
| TCP success | Controlled loopback listener | `connected`, correct port/address, non-negative latency. |
| TCP refusal | Recently closed loopback port or injected `ECONNREFUSED` | `refused`; never timeout or permission denied. |
| Timeout | Injected poll/connection timeout; avoid relying on a public unroutable IP | `timedOut` at the connect stage, within tolerance. |
| No route / host unreachable | Inject errno through socket adapter | `unreachable` with original errno retained. |
| Permission error | Inject `EACCES` and `EPERM`; additionally run signed-app Local Network matrix | POSIX case classified as permission-related; Local Network denial identified only when platform path evidence says so. |
| Resolver failure | Existing resolver fixture/errors | Resolution reason retained; no port-state assertion. |
| Cancellation before/during attempt | Pre-cancel and blocked readiness fixture | Terminal `cancelled`; no next address/port is started; descriptors close. |
| Multi-address aggregate | Inject ordered IPv4/IPv6 outcomes | Deterministic result and preserved per-address evidence; no false `closed`. |
| Empty vs command failure | Fake process adapter returns empty success, missing binary, non-zero, timeout and permission error | Empty is a valid empty inventory; each failure has distinct stable reason. |
| Output budget | Child emits beyond stdout and stderr caps concurrently | Process continues to be drained; retained bytes stay bounded; truncation flag is set. |
| Child cleanup | Child waits, ignores SIGTERM, or spawns a child process | Runtime follows documented ownership policy; no owned process is left running after terminal state. |
| Total deadline | Slow resolver plus multiple address attempts/retry fixture | Whole job respects one deadline; substeps cannot each reset the full budget. |
| GUI/MCP consistency | Same injected result through both adapters | Stable reason/code and target metadata match; only presentation differs. |
| Persisted history compatibility | Load old asset JSON and save/read new result | Existing data remains readable; structured error metadata is additive or migrated with a tested version path. |

Physical-device matrix: signed app bundle; macOS 15.0 only if still in the supported matrix, macOS 15.1+, and current supported macOS; local target with permission allowed, denied, and undecided in a fresh user or VM snapshot; non-local target; Wi-Fi and Ethernet where available. Record app signature, OS build, target class, user action, observed error/path state and recovery. Do not attempt to reset privacy state by editing undocumented system databases.

## PR 拆分与交付清单 / PR split and delivery checklist

1. **T01a — TCP outcome model:** typed socket result and deterministic tests; no persistence/UI expansion beyond required scanner labels.
2. **T01b — inventory command results:** migrate callers incrementally from empty-on-error to explicit state; issue #14 closes only after all agreed callers and evidence are covered.
3. **T03a — runtime contract:** Job spec/state/event/result types and TCP diagnostic vertical slice; document per-process budgets.
4. **T03b — process adapter:** bounded output, cancellation/timeout cleanup, and traceroute migration; add subprocess stress fixtures.

Before opening each implementation PR, attach: changed behavior, failure mapping table, tests run on macOS 15 Intel and macOS 26, fixture output, any UI/localization changes, schema/MCP compatibility notes and known device-test gaps. Do not mark physical Local Network privacy or notarization acceptance as passed based on CI socket fixtures.

## 尚待评审 / Open questions

- Should the durable result store an errno integer, a stable symbolic code, or both? Recommendation: stable code plus optional numeric errno; never depend on localized text.
- For multiple addresses, should the UI show each attempt or only a summary with expandable evidence? Recommendation: store attempts, show concise aggregate by default.
- Should a timeout display `No response` rather than `Filtered`? Recommendation: use `No response` unless another probe provides evidence for filtering.
- Which system-command-backed inventory should be migrated first? Recommendation: `SocketInventory`, because permission-related omissions materially change the meaning of an empty list; confirm product expectation before broadening scope.
- Does release signing use a stable Apple-issued identity in all supported distributions? This affects whether Local Network privacy behavior can be reliably associated with the app; record the actual signing identity in the device-test evidence.

## Sources / 资料

- [Apple TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — Local Network privacy behavior, macOS considerations, TCP operations and the `NWConnection` path-state signal.
- [T01 issue #14](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) and [T03 issue #16](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) — accepted scope and implementation tracking.
- [T01/T03 backlog](NEXT_GENERATION_BACKLOG_2026-11-09.md) and [architecture proposal](NEXT_GENERATION_RESEARCH_2026-11-09.en.md) — parent design and estimates.
