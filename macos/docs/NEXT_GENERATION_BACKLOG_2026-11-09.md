# 实施任务清单 / Implementation backlog

[中文方案](NEXT_GENERATION_RESEARCH_2026-11-09.zh-CN.md) · [English proposal](NEXT_GENERATION_RESEARCH_2026-11-09.en.md) · [Index / 索引](README.md)

研究基准 / Research baseline: 2026-11-09. 修订 / Revised: 2026-11-14.

以下保留原始任务提案、估算与验收范围。当前七个实现切片覆盖 T01/T02/T03，0/16 主项满足全部验收；最新推进见 [Ping 总预算记录](T03_PING_BUDGET_2026-11-14.md)与[同日 DNS 记录](PROGRESS_2026-11-14.md)，远端状态见 PR #20。估算为开发人日，依赖表示实施顺序；P0/P1/P2 表示优先级，不等于固定日历阶段。T15 从第一周持续推进，最终发布前需复核。

The original proposals, estimates and acceptance scope are retained below. Seven implementation slices cover T01/T02/T03, with 0/16 fully accepted; see the [Ping budget record](T03_PING_BUDGET_2026-11-14.md), [same-day DNS record](PROGRESS_2026-11-14.md) and PR #20 for current delivery status. Estimates are engineering person-days; dependencies describe ordering. Priorities do not set calendar dates. T15 runs throughout the work and must be checked again against the final release build.

完整任务集不构成 90 天交付承诺。两名工程师和共享 QA/实验环境是阶段估算的前提；单人应收敛至 P0 和一个完整排障流程。

The full backlog is not a 90-day commitment. Phase estimates assume two engineers with shared QA and lab access; a single developer should limit scope to P0 and one complete troubleshooting workflow.

[CSV](NEXT_GENERATION_BACKLOG_2026-11-09.csv) · [JSON](NEXT_GENERATION_BACKLOG_2026-11-09.json) · [Interactive board / 交互看板](NEXT_GENERATION_ROADMAP_2026-11-09.html)

## 中文

| ID | 优先级 | 工作项 | 人日 | 依赖 | 验收条件 | 跟踪 |
|---|---|---|---|---|---|---|
| T01 | P0 | 类型化 TCP/权限/依赖错误 | 3-5 | — | 拒绝、超时、无路由、取消分别返回；权限不足不显示空成功 | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) |
| T02 | P0 | 系统 resolver 与显式 DNS 分离 | 4-7 | T01 | VPN split DNS、IPv6 nameserver、.local、多网卡 fixture 与实机矩阵 | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/15) |
| T03 | P0 | Job runtime 与有界进程适配器 | 8-12 | T01 | 总 deadline、进程预算、取消、输出截断、退出清理贯通 GUI/MCP | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) |
| T04 | P0 | Repository 与 SQLite 迁移 | 8-12 | — | 旧 JSON 可验证迁移；磁盘失败/中断不破坏原数据；分页可基准测试 | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/17) |
| T05 | P1 | 稳定外部身份与接口双栈模型 | 5-8 | T04 | 同 remoteID 换 IP 保留历史；多 VRF/重复 IP 不误合并 | — |
| T06 | P1 | Case/Observation 与服务诊断链 | 8-12 | T02, T03, T04, T05 | DNS 到 TCP 到 TLS/HTTP 结构化证据可恢复并导出 | — |
| T07 | P1 | Zabbix 指标时间窗与事件关联 | 4-7 | T05, T06 | 告警前后窗口、单位、来源、采样间隔、空数据、权限、时差均可解释 | — |
| T08 | P1 | ConnectionProfile/LaunchPlan/跳板 | 5-8 | T03, T05 | ProxyJump、转发启停、主机密钥变化、恢复布局不执行命令 | — |
| T09 | P1 | ToolProvider 与 iperf3 纵向切片 | 7-10 | T03, T06 | 缺工具、版本差异、两端正反向、时长预算、取消可验证 | — |
| T10 | P1 | MCP Case 快照与排障计划 | 5-8 | T03, T06 | 作用域、预算、过期计划由执行层拒绝；schema 与 GUI 一致 | — |
| T11 | P2 | LibreNMS/NetBox 只读拓扑 | 6-10 | T05, T06 | 邻居、端口、来源、时间、冲突、陈旧边可解释 | — |
| T12 | P2 | pcapng 离线证据摘要 | 4-7 | T03, T06 | 大/损坏文件、分析取消、hash、敏感附件、保留规则可验证 | — |
| T13 | P2 | gNMI 只读试点 | 6-10 | T03, T05, T06 | 两类实际设备的 Capabilities/Get、TLS、断线、不支持模型可验证 | — |
| T14 | P2 | 配置备份/diff 与只读设备驱动 | 6-10 | T06, T08 | 两类 OS 配置可比；完整性和脱敏通过；默认不写配置 | — |
| T15 | P0 | 实机互操作与正式发布 gate | 6-10 | — | 实际平台/设备、支持 OS/CPU、升级、签名、公证、Gatekeeper 有证据 | — |
| T16 | P1 | 严格并发检查与 MainActor/actor | 4-7 | T03, T04 | 共享可变状态风险收敛；取消和并行 fixture 通过 | — |

## English

| ID | Priority | Work item | Days | Dependencies | Acceptance | Tracking |
|---|---|---|---|---|---|---|
| T01 | P0 | Typed TCP, permission and dependency failures | 3-5 | — | Return distinct refusal, timeout, unreachable and cancellation reasons; never present a permission failure as an empty success. | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) |
| T02 | P0 | System resolution and explicit DNS queries | 4-7 | T01 | Cover VPN split DNS, IPv6 name servers, .local and multiple interfaces with fixtures and a real-Mac matrix. | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/15) |
| T03 | P0 | Job runtime and bounded process adapter | 8-12 | T01 | Enforce total deadlines, per-process budgets, cancellation, output truncation and exit cleanup with consistent GUI/MCP semantics. | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) |
| T04 | P0 | Repository abstraction and SQLite migration | 8-12 | — | Verify migration from old JSON; preserve originals on disk failure or interruption; benchmark indexed pagination. | [Issue](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/17) |
| T05 | P1 | Stable external identity, interfaces and dual stack | 5-8 | T04 | Retain history when a remoteID changes IP; avoid incorrect merges across VRFs or duplicate IPs. | — |
| T06 | P1 | Case/Observation and service diagnostic chain | 8-12 | T02, T03, T04, T05 | Persist and export structured DNS to TCP to TLS/HTTP evidence; reopen a Case and rerun its checks. | — |
| T07 | P1 | Zabbix metric windows and incident correlation | 4-7 | T05, T06 | Explain before/after windows, units, sources, sampling intervals, empty data, permission failures and clock differences. | — |
| T08 | P1 | ConnectionProfile, LaunchPlan and jump hosts | 5-8 | T03, T05 | Verify ProxyJump, forwarding start/stop and changed host keys; restoring the layout sends no commands. | — |
| T09 | P1 | ToolProvider and an iperf3 workflow | 7-10 | T03, T06 | Verify missing tools, version differences, forward/reverse endpoint measurements, duration budgets and cancellation. | — |
| T10 | P1 | MCP Case snapshots and diagnostic plans | 5-8 | T03, T06 | Reject out-of-scope, over-budget or expired plans in the execution layer; keep result schemas consistent with the GUI. | — |
| T11 | P2 | Read-only LibreNMS/NetBox topology | 6-10 | T05, T06 | Explain neighbors, endpoint ports, sources, timestamps, conflicts and stale edges. | — |
| T12 | P2 | Offline pcapng evidence summaries | 4-7 | T03, T06 | Verify large/corrupt files, cancellation, hashes, sensitive attachments and retention rules. | — |
| T13 | P2 | Read-only gNMI pilot | 6-10 | T03, T05, T06 | Verify Capabilities/Get, TLS, disconnects and unsupported models on two real device families. | — |
| T14 | P2 | Configuration backups, diffs and read-only drivers | 6-10 | T06, T08 | Compare configurations on two OS families; verify completeness and redaction; configuration writes stay outside this task. | — |
| T15 | P0 | Real interoperability and formal release gates | 6-10 | — | Record real platforms/devices, supported OS/CPU pairs, upgrades, signing, notarization and Gatekeeper results. | — |
| T16 | P1 | Strict concurrency and MainActor/actor boundaries | 4-7 | T03, T04 | Resolve shared mutable-state risks module by module; pass cancellation and concurrent execution fixtures. | — |

## 数据格式 / Data format

JSON schemaVersion 2 使用 workItem 和 acceptance 的 zh-CN/en 对象；estimatePersonDays 是范围字符串，dependencies 是任务 ID 数组。status=proposed 表示计划状态。issueURL 仅在建立议题后填写；当前进展以议题中的实现与验收记录为准。CSV 每项一行，以分号分隔依赖；本页和 HTML 是该 JSON 的阅读视图。

JSON schemaVersion 2 stores workItem and acceptance as zh-CN/en objects, estimatePersonDays as a range string, and dependencies as an array of task IDs. status=proposed records planning status. issueURL is populated once a tracking issue exists; implementation links and acceptance evidence in that issue establish current progress. CSV uses one row per task and semicolons between dependencies. This page and the HTML board are reading views of the JSON.
