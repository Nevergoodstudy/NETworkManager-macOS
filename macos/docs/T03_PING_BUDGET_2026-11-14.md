# T03 Ping 总预算与取消 / Ping total budget and cancellation

日期 / Date: **2026-11-14 · Asia/Shanghai**

交付分支 / Delivery branch: codex/t01-t03-runtime · [PR #20](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/20) · [T03 #16](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) · [总跟踪 / Overall #13](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/13)

[计划索引 / Index](README.md) · [同日 DNS 与平台跟进 / DNS and platform follow-up](PROGRESS_2026-11-14.md) · [批次进度与取消 / Batch progress and cancellation](T03_BATCH_PROGRESS_2026-11-11.md)

## 中文

本批继续加固已有 T03 runtime 切片，修复单次 Ping 在解析、原生 ICMP 和系统回退中重复获得超时预算的问题，并纠正 IPv6 回退参数和 MCP 中过时的超时说明。保留已有七个实现切片的统计，T01/T02/T03（3/16 主项）有实现，**整项验收仍为 0/16**。

### 执行契约

- Ping.once 在提交阻塞工作前建立一个 ContinuousClock 截止时间，排队、一次地址解析、原生探测和可选系统回退共用剩余预算。每个阶段前后检查取消和到期；已超时的阶段不能通过返回迟到成功来启动后续工作。
- 解析只执行一次，原生探测和子进程使用同一个数字地址。原生探测最多使用解析后剩余时间的一半，为 Darwin 系统客户端兼容回退预留时间；初始化失败也可在剩余预算内回退。
- 无显式 token 时仍建立 DiagnosticCancellation，并用 withTaskCancellationHandler 桥接 Swift Task 取消，包括进入函数前已取消的任务。阻塞阶段在 DispatchQueue 工作线程执行。
- 原生接收改用最长 50 ms 的 poll 与非阻塞 recvmsg。静默、临时就绪错误及不匹配的 echo 序号不会重置截止时间；RTT 也使用单调时钟。附属 TTL 数据在读取前校验声明长度与实际缓冲区边界。
- 系统回退使用现有 ProcessRuntime、参数数组、固定数值地址、每条输出流 16 KiB 上限和 0.05 秒终止宽限。IPv4 使用 ping 的毫秒等待与 TTL 参数；IPv6 使用 ping6 的 hoplimit 参数，不把 IPv4 的 -W 参数套用到 ping6。
- 输出解析保留 IPv6 地址中的冒号，支持 hlim，并保留调用者的序号。Swift API 接受有限且大于零、不超过 86,400 秒的预算；无效值在 Duration/整数转换和网络操作前拒绝。MCP 继续限制在 0.1–5 秒。
- 复用 ICMPPinger 的构造器解析有独立的受限预算；每次 ping 的原生接收和回退共享该次预算。此接口不声称将构造器与多个 echo 合并成一个任务级 deadline。

网络预算不等于严格的请求完成时限：子进程终止、输出收尾与回收使用现有运行时的有界清理逻辑，可能晚于网络截止时间结束。此变更没有建立跨 GUI/多个 MCP 进程的全局配额。

### 本机验证与证据

环境：arm64、macOS 27.2.1（26B131）、Apple Swift 6.4.2。Swift 5 语言模式与 macOS 14 最低版本未改。既存 CommandLineTools framework/library 搜索路径告警仍为非致命。

| 检查 | 结果 | 本机临时日志 |
|---|---|---|
| NMTest --ping-only | 通过；无效预算、共享时钟、数字地址复用、初始化错误回退、每阶段到期/取消与迟到结果 | /tmp/networkmanager-ping-20261114/focused.log |
| Swift Task 与原生接收 fixtures | 通过；开始前与各阶段运行中取消、无回复、持续无关报文、匹配 echo、短 TTL 附属数据 | 同上 |
| IPv4/IPv6 回环 | Ping.once 和直接 SystemPing 均通过；解析器保留地址、TTL/hlim 与请求序号 | 同上 |
| 完整 NMTest | 通过；包括新增 Ping 与已有 DNS、采集、进程、MCP 客户端回归 | /tmp/networkmanager-ping-20261114/full.log |
| NMCheck | 通过；包括 SNMPv3 密码向量 | /tmp/networkmanager-ping-20261114/self-check.log |
| Debug 应用与内置 NMCP | 通过；构建、暂存 .app，并经 LaunchServices 确认进程从该 bundle 运行 | /tmp/networkmanager-ping-20261114/app.log |
| 签名完整性 | codesign --verify --deep --strict --verbose=2 通过；仅为 ad-hoc 构建 | /tmp/networkmanager-ping-20261114/signature.log |
| MCP 集成 | 通过；既有协议/离线/回环/时限/取消/并发/launcher 检查，新增 ::1 Ping 与 Ping/DNS 总预算 schema 断言 | /tmp/networkmanager-ping-20261114/mcp.log |

确定性阶段 fixture 使用 1 秒总预算：解析消耗 0.4 秒，原生获分 0.3 秒并消耗该预算，回退只剩 0.3 秒。每个阶段分别模拟取消和超时，验证不启动后续阶段。静默与持续错误序号报文各使用 0.12 秒预算、0.5 秒测试上限；接收和任务取消也要求在 0.5 秒内返回。专项与 MCP 网络检查仅使用本机 fixtures/回环；这些测试上限不是生产实时性保证。临时日志不随仓库分发。

本批未进行新的 GUI 交互验收、真实 IPv6-only 网络验证或正式身份权限矩阵。IPv6 回环不等于 IPv6-only 网络，ad-hoc 签名不等于 Developer ID、公证或 Gatekeeper 验收。T03 仍需更广泛 GUI/MCP 作业接入、统一跨路径预算、排队/partial/慢消费/断开/退出/无遗留任务与 schema/配额边界验证。T01/T02 既有平台、网络与受控 GUI gates 保持开放；T04 未新增实现。

## English

This batch hardens the existing T03 runtime slice: a single Ping no longer renews its timeout for resolution, native ICMP and system fallback. It also corrects IPv6 fallback flags and the stale MCP Ping/DNS timeout descriptions. There are still seven implementation slices across T01/T02/T03 (3/16 main items with implementation), with **0/16 fully accepted**.

Ping.once creates one ContinuousClock deadline before dispatching blocking work. Queueing, one resolution, the native attempt and optional fallback consume its remaining budget. Cancellation and expiry are checked before and after each phase, including late successful returns. The resolved numeric endpoint is reused. The native attempt receives half the post-resolution remainder, reserving time for Darwin system-client compatibility fallback; native setup errors can also fall back.

Swift task cancellation is bridged to a shared token even when the caller supplies none or was already cancelled. Blocking work runs off cooperative workers. Native receive uses poll intervals of at most 50 ms and nonblocking recvmsg, so silence and unmatched echo sequences do not renew the deadline. RTT uses the monotonic clock. Ancillary TTL reads validate both declared length and buffer bounds.

System fallback uses the existing ProcessRuntime, argument arrays, a numeric address, 16 KiB per-stream output caps and a 0.05-second termination grace. IPv4 uses ping's millisecond wait/TTL flags; IPv6 uses ping6's hoplimit flag without the incompatible IPv4 -W option. The output parser preserves IPv6 colons, accepts hlim and retains the requested sequence. Swift API budgets must be finite, positive and at most 86,400 seconds; MCP retains its 0.1–5-second limit.

For a reusable ICMPPinger, constructor resolution is separately bounded; each echo shares its own budget across native receive and fallback. This is not a combined constructor/multiple-echo job deadline. Bounded subprocess teardown may finish after the network deadline; the API does not promise a strict wall-clock request-completion limit. Process quotas remain local to each process.

### Validation and remaining gates

The focused Ping suite, full NMTest, NMCheck, Debug app/bundled NMCP build, LaunchServices startup, ad-hoc signature verification and MCP integration all passed on arm64 macOS 27.2.1 (26B131), Swift 6.4.2. MCP tests now assert total-budget descriptions/bounds and IPv6 loopback Ping. Existing toolchain search-path warnings remain non-fatal. Swift 5 language mode and the macOS 14 minimum are unchanged. The table above lists local temporary evidence logs, not portable repository artifacts.

Deterministic phase fixtures consume a one-second budget: 0.4 seconds for resolution, 0.3 seconds for native ICMP and only the remaining 0.3 seconds for fallback. They also test invalid budgets, setup failure, cancellation/expiry after every phase, late results, pre-cancelled tasks and in-flight task cancellation. Local datagram fixtures exercise silence, unmatched traffic, matching replies, cancellation and short ancillary data. Silence/flood tests use a 0.12-second deadline and a 0.5-second assertion ceiling; cancellation must return within 0.5 seconds. Both Ping.once and direct SystemPing pass IPv4/IPv6 loopback checks. Focused/MCP networking uses only local fixtures/loopback; assertion ceilings are not production real-time guarantees.

No new GUI interaction or formal signed-permission matrix was accepted in this batch. IPv6 loopback is not IPv6-only network acceptance, and ad-hoc verification is not Developer ID/notarization/Gatekeeper acceptance. Wider GUI/MCP adoption, unified budgets, lifecycle/backpressure/orphan checks and schema/quota boundaries remain open for T03. Existing T01/T02 platform, network and controlled-GUI gates remain open; T04 received no implementation. Remote CI is recorded per commit in PR #20 and tracking issues, without treating historical success as evidence for a new commit.

## 复现 / Reproduce

Run sequentially from the repository root on macOS:

~~~bash
NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-ping-check.XXXXXX)" swift run --package-path macos NMTest --ping-only
NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-full-check.XXXXXX)" swift run --package-path macos NMTest
NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-self-check.XXXXXX)" swift run --package-path macos NMCheck
CONFIGURATION=debug script/build_and_run.sh --verify
/usr/bin/codesign --verify --deep --strict --verbose=2 dist/macos/NETworkManager.app
NMCP_CONFIGURATION=debug python3 macos/Scripts/test-mcp.py --server macos/.build/debug/NMCP --launcher macos/Scripts/run-mcp.sh
git diff --check
~~~

## 实现与研究依据 / Implementation and research

- [Ping orchestration and fallback](../Sources/NMCore/Net/PingExecution.swift), [native ICMP](../Sources/NMCore/Net/ICMP.swift), [focused fixtures](../Sources/TestRunner/PingChecks.swift), [MCP contract](../Sources/NMMCPTools/MCPToolService.swift), [MCP integration](../Scripts/test-mcp.py).
- [Swift SE-0304: structured concurrency and cancellation handlers](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0304-structured-concurrency.md). Official source retrieved using GitHub API; this verifies the handler-before-operation behavior for already-cancelled tasks.
- [Apple ContinuousClock](https://developer.apple.com/documentation/swift/continuousclock). Official clock documentation consulted during this work; local Darwin ping(8)/ping6(8) manuals verified the family-specific options. Public web search was attempted but returned no usable results; a direct raw-source request timed out, and the official GitHub API retrieval succeeded.
- Applied the loaded build-run-debug, test-triage and swiftui-patterns skills: focused checks first, then full tests and staged application verification. No production test controls were added.
