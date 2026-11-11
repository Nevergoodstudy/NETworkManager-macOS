# T03 批量扫描进度与取消 / Batch scan progress and cancellation

日期 / Date: 2026-11-11

本地分支 / Local branch: `codex/socket-inventory-local`
交付范围 / Scope: IP 与 TCP GUI 批次的进度、取消和结果保留 / Progress, cancellation and result retention for IP and TCP GUI batches

[计划索引 / Plan index](README.md) · [进程适配器 / Process adapter](T01_T03_IMPLEMENTATION_2026-11-10.md) · [IP 初始化错误行 / IP setup failure rows](T03_IP_SCAN_FAILURE_2026-11-11.md)

## 中文

本批代码和 fixture 已纳入 PR #20；GUI 自动化和更广泛的 GUI/MCP 作业接入仍待完成。

IP 扫描器已有进度条，但此前 TCP 扫描没有逐端口回调，因此数字只在批次结束后更新。现在 TCP 和 IP 每完成一项目标都会更新 GUI 进度；取消结果不写入结果表，也不触发进度。扫描停止后不再派发新目标。已经从执行器返回的 IP 结果会先写入结果并计入完成数，再处理停止信号，因此停止竞态不会丢掉已完成行。

IP 批次调度被提取到可注入探测器的执行函数，生产仍使用原生 ICMP 探测。TCP 批次通过同一方式保留公开 API，并以本地可测入口注入探测函数。两种批次均用 `withTaskCancellationHandler` 将 Swift Task 取消桥接到共享 `DiagnosticCancellation`，使直接取消外层任务也能停止在途探测；UI 的 Stop 仍同时取消任务和共享 token。

进程运行时不再仅凭一次进程组 signal 错误记录清理失败。进程组成员可能恰在 signal 前退出；最终仍依据进程组无存活成员、两条输出流 EOF、leader 已回收且没有其他清理错误来确定 `cleanupCompleted`。若成员确实残留，最终状态仍为清理失败。

### 本机验证

- `swift run --package-path macos NMTest`：通过。新增 IP/TCP 批次全量进度、外层 Swift Task 取消、在途任务停止、不再派发后续目标、过滤取消结果，以及停止前已返回 IP 行保留的 fixture 检查；不访问外部网络。
- `swift build --package-path macos --product NETworkManagerMac`：Debug GUI 构建通过。
- `swift run --package-path macos NMCheck`：通过。
- `git diff --check`：通过。
- 环境：arm64、macOS 27.2.1（26B131）、Apple Swift 6.4.2；包仍为 Swift 5 语言模式，最低版本 macOS 14。
- SwiftPM 输出已有 CommandLineTools framework/library 搜索路径告警；不影响以上构建与检查。

本批没有运行 UI 自动化或真实签名身份下的权限矩阵。T03 整体验收仍包括统一总预算和更多 GUI/MCP 操作的作业语义；不得把此批视为 T03 完成。

## English

This implementation and its fixtures are included in PR #20. GUI automation and broader GUI/MCP job adoption remain open.

The IP scanner already had a progress bar, but TCP scanning had no per-port callback, so its count changed only when the batch ended. Both TCP and IP scans now update GUI progress as each target completes. Cancelled outcomes do not enter the result table or advance progress. No new target is dispatched after cancellation. An IP result already returned by the executor is recorded before the stop signal is handled, so a cancellation race does not discard a completed row.

The IP batch scheduler is now an injectable execution function; production still uses native ICMP probes. The TCP batch retains its public API and uses an internal injectable seam for deterministic tests. Both schedulers bridge cancellation of the owning Swift Task to their shared `DiagnosticCancellation` with `withTaskCancellationHandler`, so direct task cancellation also stops in-flight probes. The UI Stop action continues to cancel both the task and shared token.

The process runtime no longer records a cleanup failure solely from one process-group signal error. A group member may exit just before the signal. Final cleanup still requires no live group members, EOF on both output streams, a reaped leader and no other cleanup errors. A group that actually remains alive still fails cleanup.

### Local verification

- `swift run --package-path macos NMTest`: passed. New local fixtures cover complete IP/TCP progress, owning Swift Task cancellation, in-flight stop, no further dispatch, filtering cancelled outcomes, and retention of an IP row returned before stop; no external network target is used.
- `swift build --package-path macos --product NETworkManagerMac`: Debug GUI build passed.
- `swift run --package-path macos NMCheck`: passed.
- `git diff --check`: passed.
- Environment: arm64, macOS 27.2.1 (26B131), Apple Swift 6.4.2; the package remains in Swift 5 language mode with macOS 14 as its minimum.
- SwiftPM emits existing CommandLineTools framework/library search-path warnings; the checks above succeeded.

This batch did not run UI automation or a permission matrix under a signed identity. Full T03 acceptance still includes one total budget and consistent job semantics across more GUI/MCP operations; this batch does not complete T03.
