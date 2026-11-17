# T03 IP 扫描目标失败行 / IP scan target failure rows

日期 / Date: 2026-11-11

本地分支 / Local branch: `codex/socket-inventory-local`
交付范围 / Scope: T03 单目标扫描错误可见性 / T03 per-target scan failure visibility

[计划索引 / Plan index](README.md) · [TCP 与有界进程 / TCP and bounded processes](T01_T03_IMPLEMENTATION_2026-11-10.md)

## 中文

本批代码和测试已纳入 PR #20；单目标初始化失败行已覆盖，批次级并发与统一预算仍按 #16 跟踪。

IP 扫描器原先用 `try?` 创建 `ICMPPinger`。主机名解析或 ICMP socket 初始化抛错时，异常被转换成 `nil`。调度器仍会将这个目标计入完成数，但不会把目标加入结果表，用户看到的进度和结果数量因此不一致。

现在探测初始化错误会作为失败结果行返回，保留目标和 `localizedDescription`；任务或扫描被取消时仍返回无行，避免把取消呈现为目标故障。单目标执行增加一个可注入的探测闭包，生产默认实现不变，测试可以确定性地模拟初始化错误，无需依赖 DNS 或外网。

### 本机验证

- `swift run --package-path macos NMTest`：通过；新增注入初始化错误及预先取消两种检查。
- `swift build --package-path macos --product NETworkManagerMac`：Debug 应用构建通过。
- `swift run --package-path macos NMCheck`：通过。
- 环境：arm64、macOS 27.2.1（26B131）、Apple Swift 6.4.2；Swift 5 语言模式与 macOS 14 最低版本未变。
- SwiftPM 仍输出已有 CommandLineTools framework/library 搜索路径告警；本次检查成功。

本条错误行修复本身没有改动批量扫描并发上限、目标范围限制或 TCP 端口扫描调度。后续本地切片已为 IP/TCP GUI 批次接入进度和运行中取消，详见 [T03 批次记录](T03_BATCH_PROGRESS_2026-11-11.md)。更广泛的 GUI/MCP 作业接入和完整 T03 验收仍未完成。

## English

This implementation and its tests are included in PR #20. Per-target setup failures are covered; batch concurrency and unified budgets remain tracked under #16.

The IP scanner previously used `try?` when creating `ICMPPinger`. A hostname-resolution or ICMP-socket initialization error became `nil`. The scheduler still counted that target as complete, but omitted its row, so progress and visible results could disagree.

Initialization failures now return a failed row that retains the target and the error's `localizedDescription`. Cancellation still returns no row, so a cancelled target is not reported as a host failure. A probe closure can be injected at the per-target boundary; the production default is unchanged, and tests can reproduce initialization failure without relying on DNS or an external network.

### Local verification

- `swift run --package-path macos NMTest`: passed, including injected initialization failure and pre-cancelled target checks.
- `swift build --package-path macos --product NETworkManagerMac`: Debug app build passed.
- `swift run --package-path macos NMCheck`: passed.
- Environment: arm64, macOS 27.2.1 (26B131), Apple Swift 6.4.2; Swift 5 language mode and the macOS 14 minimum are unchanged.
- SwiftPM continues to emit existing CommandLineTools framework/library search-path warnings; checks succeeded.

This per-target error-row change did not alter batch concurrency limits, target-range limits or TCP port-scan scheduling. A later local slice adds progress and in-flight cancellation to the IP/TCP GUI batches; see the [T03 batch record](T03_BATCH_PROGRESS_2026-11-11.md). Broader GUI/MCP job adoption and full T03 acceptance remain open.
