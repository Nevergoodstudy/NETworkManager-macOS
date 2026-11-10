# T01 TCP 与 T03 进程适配器 / TCP outcomes and bounded process execution

日期 / Date: 2026-11-10 · 基线 / Base: `08840c6` (`main`) · 实施分支 / Branch: `codex/t01-t03-runtime`

[计划索引 / Plan index](README.md) · [T01 #14](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) · [T03 #16](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) · [准备评审 / Preparation review #19](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/19)

## 中文

本次交付 TCP 结果语义和一个可复用的有界进程适配器，Traceroute 是首个接入统一诊断服务的命令工具。T01 的系统清单错误状态迁移、T03 的多目标作业及更多 GUI/MCP 操作仍留在原议题中。这份记录描述实施分支的行为，不代表整份路线图已完成或已正式发布。

### 使用上的变化

- TCP 只有明确收到连接拒绝、且所有已解析地址均明确拒绝时显示关闭。解析失败、无路由、权限错误和执行错误分别保留；超过期限显示“无响应”。
- 系统解析与全部地址尝试共用一个单调时钟期限。地址切换不会重新获得完整 timeout；取消或预算用尽后不再创建下一个 socket。
- 逐地址证据保留数字地址、地址族、阶段、初始 connect errno、失败系统调用 errno、SO_ERROR、poll 事件、EINTR 次数和耗时。成功连接到后备地址时，之前的失败尝试仍可查。
- 扫描器关闭“显示关闭端口”后，错误和无响应结果仍然可见。越界端口范围不再触发反向 ClosedRange 崩溃。
- Traceroute 工具页和资产诊断使用同一诊断服务。取消和超时保留已收集的输出、截断信息和清理证据。资产界面不再用迟到的取消信号重写已经结束的结果。

### 进程执行契约

`Shell.run` 与 `runSync` 共用 `ProcessRuntime`。旧方法签名及 `CommandResult` 的原有字段继续可用，新增字段提供稳定失败分类、作业身份、生命周期事件、输出计数和清理结果。

| 边界 | 当前实现 |
|---|---|
| 作业规模 | 一个作业执行一个命令、一个目标；`maximumTargetCount` 和 `concurrency` 固定为 1。批量调度尚未接入。 |
| 本进程预算 | 最多同时持有 4 个命令作业；超出直接返回 `busy`。尚未回收的 leader 转交后台 reaper 时，permit 一并转交，回收后才释放。MCP 自身的诊断预算另行保留。 |
| 期限 | 创建 spec 时把公开 Date 期限换算为 uptime 期限；派发、启动、运行共用剩余预算。预取消和过期任务在 spawn 前返回。 |
| 输出 | stdout、stderr 各默认保留 1,048,576 原始字节；单流可设为 0，硬上限 16,777,216。Traceroute 每流保留 128,000。达到保留上限后继续排空，并记录实际读到的字节数。 |
| 生命周期 | 有界 `queued → running → terminal` 事件；启动前拒绝时没有 running。终态为 succeeded、failed、timedOut 或 cancelled。 |
| 进程所有权 | `posix_spawn` 创建独立进程组。单个 worker 负责双流读取、取消检查、信号及回收。`waitid(WNOWAIT)` 保留退出的 leader，所有组信号完成后才 `waitpid`。回收之后不再向该 PGID 发信号。 |
| 终止与收尾 | 向所拥有进程组发 TERM；宽限期默认 0.5 秒，可设 0…2 秒；有活成员时升级 KILL，再最多等待 1 秒收尾。持续输出的每轮读取有次数上限，不能一直占住生命周期循环。 |
| 清理证据 | 用 `KERN_PROC_PGRP` 快照排除 zombie，区分活后代与退出 leader。确认 leader 已回收、组无活成员、两流 EOF 且没有清理错误后，`cleanupCompleted` 才为 true。 |

`forcedTermination` 表示实际尝试向活成员或状态未知的拥有组发送 KILL。输出计数区分读取字节、原始保留字节及 UTF-8 展示字节；损坏编码和字符边界也不能让展示超出上限。Traceroute 历史预览最多 8,000 字符，预览截断同样显示提示。

这个所有权边界覆盖仍在初始进程组内的后代。主动新建 session 或离开组的后代不在覆盖范围内；若其持有管道导致 EOF 无法到达，收尾会有界返回并明确报告清理未完成。内核 spawn 本身没有可取消接口；期限约束监督循环及清理等待，不宣称能中断内核调用。

### 数据与接口兼容

`DiagnosticRun.evidence` 是新增可选字段；旧 JSON 缺少该字段仍可加载。资产保存、恢复和 JSON/Markdown 证据导出保留同一份结构化数据。导出器对嵌套消息和清理文本同样执行脱敏，导入记录中的 token 等敏感文本不会因为进入新字段而跳过既有规则。

MCP `tcp_probe` 保留原有顶层响应字段，新增可选 `evidence.tcpAttempts` 与 `evidence.tcpFailure`。文本 JSON 和 structuredContent 内容一致。TCP timeout 从每阶段预算改为整体预算，工具 schema 和使用说明已同步。MCP 当前工具集保持原有范围；Traceroute 本次接入 GUI 和资产诊断。

错误文本不用于 TCP 分类。`errno` 与 `SO_ERROR` 分别记录。普通 socket 的 EACCES/EPERM 表示权限相关失败；超时不推断为 macOS Local Network 隐私拒绝。签名应用的实际授权状态仍需专门验收。

### 验证

本机：Apple Silicon arm64，macOS 27.2.1（26B131），Apple Swift 6.4.2。包继续使用 Swift 5 语言模式，最低平台保持 macOS 14。

| 检查 | 结果 / 覆盖 |
|---|---|
| `swift run --package-path macos NMTest` | 通过。包含原有协议/集成检查，以及新增 TCP、进程、持久化和导出回归。 |
| `swift run --package-path macos NMCheck` | 通过。协议与 SNMPv3 crypto vectors 自检。 |
| `swift build --package-path macos` | 通过。全部 Debug products，包括 GUI 和 NMCP。 |
| `python3 macos/Scripts/test-mcp.py --server macos/.build/debug/NMCP` | 通过。真实 stdio、loopback ICMP/TCP/DNS、取消、并发、退出和新增 TCP evidence 断言。 |
| Release arm64 应用包 | `CONFIGURATION=release ARCHITECTURE=arm64 CODESIGN_IDENTITY='' CREATE_DMG=0 macos/Scripts/build-app.sh` 通过。使用本地 ad-hoc 签名。 |
| 签名与 Info.plist | `codesign --verify --deep --strict`、`plutil -lint` 通过。 |
| 打包后 MCP | `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 python3 macos/Scripts/test-mcp.py --app dist/macos/NETworkManager.app` 通过，包括移动到含空格路径、签名复核和无开发工具环境。 |
| Release GUI 启动 | 隔离 support 目录下保持运行 4 秒，通过后结束该测试进程；未宣称交互功能或真实权限矩阵已验收。 |

TCP fixture 覆盖即时/异步连接、拒绝、无路由、权限、poll 与 getsockopt 失败、EINTR、无效事件、解析错误、取消、多个地址混合失败、共享 deadline、SO_ERROR 读取跨 deadline、端口解析边界和描述符释放。系统调用通过窄接口模拟；真实成功/拒绝另用 loopback listener 核对。

进程 fixture 覆盖正常/非零退出、ENOENT/EACCES、stdin EOF、两个同时写入的输出流（各 131,072 字节、各保留 4,096 字节）、零保留上限、UTF-8 边界、持续写入、预取消、过期不启动、运行中取消、忽略 TERM、继承管道的后代、终态竞争和四任务预算。

缺失 CommandLineTools Developer framework 搜索目录的 linker warning 在本机仍存在；本轮构建和执行均完成。测试日志没有作为原始附件提交，避免把本机网络地址和临时路径带入仓库。

### 后续验收

T01 仍需逐个把系统清单从“失败时空列表”迁到明确状态；本次没有一次改写所有 inventory 调用者。T03 仍需把多目标 TCP/scanner 作业、进度事件与更多 MCP 操作接入统一预算。旧 `streamLines` API 本次未迁移，当前仓库没有调用者。

macOS 15 Intel、macOS 26、Apple-issued 身份签名后的 Local Network 允许/拒绝/未决定矩阵、真实路由器及 VPN split DNS、Developer ID 公证和 Gatekeeper 发布验收仍待记录。现有 CI 矩阵负责受支持 runner 上的构建、fixture、打包检查；本机成功不替代这些环境。

## English

This change delivers typed TCP outcomes and a reusable bounded process adapter. Traceroute is the first command tool routed through the shared diagnostic service. Inventory failure states in T01, batch jobs in T03 and further GUI/MCP adoption remain in the tracking issues. This is an implementation record for the branch, not a completed roadmap or a formal release.

### Result behavior

A TCP port is closed only when every resolved address explicitly refuses the connection. Resolution errors, routing failures, permission errors and execution failures retain separate reasons; an elapsed deadline is displayed as “No response.” Resolution and all address attempts consume one monotonic deadline. Cancellation and an exhausted budget stop further socket creation.

Each attempt records its numeric address, family, stage, initial connect errno, failing-call errno, SO_ERROR, readiness events, EINTR count and elapsed time. A successful fallback address retains earlier failures. Hiding closed ports no longer hides errors or no-response rows. Out-of-range port ranges cannot construct a reversed ClosedRange.

The Traceroute page and asset diagnostics now use the same service. Cancellation and timeout retain partial output, truncation notes and cleanup facts. The asset view preserves a completed result when a cancellation arrives afterward.

### Execution contract

`Shell.run` and `runSync` use one lifecycle owner. Existing call signatures and original `CommandResult` fields remain available. Added fields describe stable launch reasons, job identity, lifecycle events, byte counts and cleanup.

- Each job owns one command for one target. `maximumTargetCount` and `concurrency` are fixed at 1 for this slice. Batch scheduling is still pending.
- A process-wide limit allows four command jobs. Excess work returns `busy` immediately. A background reaper retains the permit until its unreaped leader is collected. MCP retains its separate diagnostic limit.
- The Date deadline becomes an uptime deadline when the spec is created. Dispatch delay, launch and execution consume the same budget. An expired or pre-cancelled job returns before spawn.
- Each stream retains at most 1,048,576 raw bytes by default, with a configurable zero-byte budget and a hard ceiling of 16,777,216. Traceroute uses 128,000 per stream. Both streams continue to drain after retention fills, with observed counts and explicit truncation.
- Events follow `queued → running → terminal`; rejection before launch omits running. The terminal state is succeeded, failed, timedOut or cancelled.
- `posix_spawn` starts a separate process group. One worker owns reads, cancellation checks, signals and reap. `waitid(WNOWAIT)` reserves the exited leader until the final group signal; `waitpid` comes afterward. No group signal is issued after reap.
- Cleanup sends TERM, allows a default 0.5-second grace period configurable within 0…2 seconds, then sends KILL when live members remain and allows one further second. Each read turn has a fixed iteration budget so continuous output cannot starve supervision.
- `KERN_PROC_PGRP` snapshots distinguish live members from zombies. Cleanup succeeds only after leader reap, no live group members, EOF on both streams and no cleanup errors.

`forcedTermination` records an actual KILL attempt against a live or unknown owned group. Raw observed bytes, raw retained bytes and UTF-8 presentation bytes have separate meanings; invalid encoding cannot expand presentation beyond its cap. Traceroute history retains an 8,000-character preview with a clipping note.

Descendants that create a separate session or leave the original group are outside this ownership boundary. If an escaped descendant holds an output descriptor, cleanup returns within its bound and records incomplete EOF. The kernel spawn call has no cancellation interface; the deadline bounds supervision and cleanup waits, rather than claiming to interrupt that call.

### Compatibility and evidence

`DiagnosticRun.evidence` is optional, so existing JSON without it remains readable. Asset persistence and JSON/Markdown export retain the structured result. Export redaction also covers nested messages and cleanup text, including imported records.

MCP `tcp_probe` retains the existing top-level fields and adds optional `evidence.tcpAttempts` and `evidence.tcpFailure`. Text JSON and structuredContent agree. TCP timeout now covers resolution plus all addresses as one budget; the schema and bilingual usage documentation describe this change. Traceroute adoption in this patch covers the GUI and asset service; the MCP tool set retains its existing scope.

TCP classification uses stable reasons rather than display text. A failing system call's errno and a successfully read SO_ERROR are stored separately. EACCES/EPERM remains a permission-related socket failure. A timeout does not establish a macOS Local Network privacy denial.

### Validation and remaining work

Local verification used arm64, macOS 27.2.1 (26B131), and Apple Swift 6.4.2. The package keeps Swift 5 language mode and its macOS 14 minimum. NMTest, NMCheck, all Debug products and the real-stdio MCP integration suite passed. The arm64 Release app bundle also built successfully with an ad-hoc signature. Deep/strict signature verification and Info.plist lint passed. The bundled MCP suite passed with the strict cooperative pool, including relocation to a path with spaces, signature checks and no developer tools. The Release GUI remained running for four seconds with an isolated support directory and was then stopped. This launch check does not establish interactive UI or real privacy-state acceptance.

Deterministic TCP checks cover connect/readiness/SO_ERROR stages, refusal, timeout, route and permission errors, cancellation, EINTR, invalid events, resolution errors, mixed addresses, deadline exhaustion during SO_ERROR, descriptor cleanup and port-range bounds. Loopback listeners also verify real successful and refused connections. The refusal fixture closes a real listener: on this Darwin version, a bound socket without listen waits rather than providing a deterministic refusal.

Process checks cover normal and nonzero exit, ENOENT/EACCES, closed stdin, simultaneous stdout/stderr writers producing 131,072 bytes each with a 4,096-byte retention cap, zero retention, UTF-8 boundaries, continuous writers, pre-cancellation, expired jobs, running cancellation, TERM escalation, inherited pipes, terminal races and the four-job limit. History checks cover old JSON, new evidence round trips, persistence, export and redaction.

The local linker still warns about missing CommandLineTools Developer framework search directories; builds and execution complete. Raw local test logs are omitted from the repository because they include interface addresses and temporary paths.

T01 still needs explicit failure states for command-backed inventories. T03 still needs batch TCP/scanner jobs, progress events and broader MCP adoption. The unused legacy `streamLines` API is unchanged by this migration. macOS 15 Intel and macOS 26 runner results, signed-app Local Network permission states, real routers, VPN split DNS, Developer ID notarization and Gatekeeper release acceptance remain separate evidence requirements.

## References / 资料

These primary sources were checked while implementing the ownership and error contracts. / 以下一手资料用于核对进程所有权与错误语义。

- [Apple TN3179 — Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple posix_spawnattr_setflags(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setflags.3.html)
- [Apple kill(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/kill.2.html)
- [Apple sysctl(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/sysctl.3.html)
- [Apple connect(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/connect.2.html)
- [Apple getsockopt(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getsockopt.2.html)
- [Apple poll(2)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/poll.2.html)
- [Apple XNU waitid and WNOWAIT implementation](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exit.c)
