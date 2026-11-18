# macOS 改进计划 / macOS improvement plan

研究日期 / Research date: **2026-11-09** · 文档修订 / Documentation revision: **2026-11-18**

**平台政策（2026-11-17）：** 当前 macOS 产品仅支持 Apple Silicon（arm64）Mac，最低 macOS 14。下方提案、数据和验收清单保留其 2026-11-09 研究时的 Universal/Intel 历史语境；涉及当前发布架构的内容已由本政策取代。

**Platform policy (2026-11-17):** The current macOS product supports Apple Silicon (arm64) Macs only, with macOS 14 as the minimum. The proposals, data and acceptance lists below retain their historical Universal/Intel context from 2026-11-09; this policy supersedes those references for current releases.

**计划基准与实施跟踪。** 方案审阅的源码是 [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8)，该功能提交于 2026-11-10 通过 [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12) 合并进 `main`。文中所列已有能力以该源码基准为准，不代表已完成真实设备互操作或正式签名公证发布。

**Planning baseline and implementation tracking.** The reviewed source is [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8), merged into `main` through [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12) on 2026-11-10. Existing capabilities in the proposal refer to that baseline; they do not establish live-device interoperability or a formally signed and notarized release.

| 内容 / Material | 入口 / Entry |
|---|---|
| T04 Repository 与 SQLite 基础（2026-11-18） / Repository and SQLite foundation (2026-11-18) | [迁移、事务、备份、验证与剩余验收 / Migration, transactions, backups, checks and remaining gates](T04_SQLITE_FOUNDATION_2026-11-18.md) |
| Apple Silicon 打包应用验收（2026-11-18） / Apple Silicon packaged-app validation (2026-11-18) | [本机运行、UI 与测试范围 / Local runtime, UI and test coverage](APPLE_SILICON_VALIDATION_2026-11-18.md) |
| T03 单次 Ping 总预算与取消 / Single-Ping budget and cancellation | [双语实施、回环验证与剩余验收 / Implementation, loopback checks and remaining gates](T03_PING_BUDGET_2026-11-14.md) |
| 2026-11-14 阶段跟进 / Stage follow-up | [DNS 可靠性、UI 验证与 CoreWLAN 评估 / DNS reliability, UI checks and CoreWLAN assessment](PROGRESS_2026-11-14.md) |
| T01 连接与监听端口的本地实施 / Local connections and listeners implementation | [双语结果契约与验证记录 / Result contract and validation](T01_SOCKET_INVENTORY_2026-11-10.md) |
| T01 ARP 与 Wi-Fi 系统采集 / ARP and Wi-Fi system collection | [双语状态与验证记录 / Result states and validation](T01_SYSTEM_INVENTORY_2026-11-11.md) |
| T02 系统解析与指定 DNS 服务器 / System resolution and specified DNS server | [双语实施与验证记录 / Implementation and validation](T02_DNS_MODES_2026-11-11.md) |
| T01 TCP 与 T03 进程适配器实施记录 / TCP and process adapter implementation | [双语实施与验证记录 / Implementation and validation](T01_T03_IMPLEMENTATION_2026-11-10.md) |
| T03 IP 扫描初始化失败可见性 / Visible IP scan setup failures | [双语实施与验证记录 / Implementation and validation](T03_IP_SCAN_FAILURE_2026-11-11.md) |
| T03 批量扫描进度与取消 / Batch scan progress and cancellation | [双语实施与验证记录 / Implementation and validation](T03_BATCH_PROGRESS_2026-11-11.md) |
| 中文架构与实施方案 | [阅读全文](NEXT_GENERATION_RESEARCH_2026-11-09.zh-CN.md) |
| English architecture and implementation proposal | [Read the proposal](NEXT_GENERATION_RESEARCH_2026-11-09.en.md) |
| 16 项任务、依赖、估算与验收 / 16 tasks, dependencies, estimates and acceptance | [双语任务清单 / Bilingual backlog](NEXT_GENERATION_BACKLOG_2026-11-09.md) |
| 表格导入 / Spreadsheet import | [Bilingual CSV](NEXT_GENERATION_BACKLOG_2026-11-09.csv) |
| 机器可读任务 / Machine-readable tasks | [JSON, schemaVersion 2](NEXT_GENERATION_BACKLOG_2026-11-09.json) |
| 交互路线看板 / Interactive roadmap | [Offline HTML](NEXT_GENERATION_ROADMAP_2026-11-09.html) |

当前处于改进计划的**第一阶段：P0 基础能力实施**。T01–T03 的七个实施切片已通过 [PR #20](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/20) 于 2026-11-17 16:47:33 UTC 合并；Apple Silicon 打包与界面修复通过 [PR #27](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/27) 于 2026-11-18 03:38:45 UTC 合并。本轮新增 T04 Repository、SQLite 迁移、事务、增量写入与分页查询基础，累计八个切片覆盖 T01–T04（4/16 主项有实现），**整项验收仍为 0/16**。本机验证、远端 CI、合并与整项验收分别记录；实际交付状态和剩余项见上表 T04 最新记录。

The project is in the **first stage: P0 foundation implementation**. Seven T01–T03 slices were merged through [PR #20](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/20) at 2026-11-17 16:47:33 UTC. Apple Silicon packaging and UI fixes were merged through [PR #27](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/27) at 2026-11-18 03:38:45 UTC. This batch adds the T04 Repository, SQLite migration, transactions, incremental writes and paginated-query foundation. Eight slices now cover T01–T04 (4/16 main items with implementation), with **0/16 whole tasks fully accepted**. Local checks, remote CI, merge and whole-task acceptance remain separate; the T04 record above contains delivery status and remaining gates.

2026-11-14 的历史跟进记录了 DNS 响应与传输加固、主要 Lookup 界面状态验证及 CoreWLAN 字段能力评估；后续补齐单次 Ping 共享总预算、取消与 IPv6 系统回退，并同步 MCP 超时契约。下方历史记录保留当时的验证范围和未完成项。

The historical 2026-11-14 follow-up records DNS parsing/transport hardening, main Lookup UI states and CoreWLAN field assessment. The subsequent Ping work adds a shared total budget, cancellation, IPv6 system fallback and matching MCP timeout contracts. Historical records below retain their original validation scope and open gates.

2026-11-10 开始实施 T01 的 TCP 结果语义和 T03 的进程适配器切片，代码、兼容性和本机验证见上表实施记录；两项完整验收继续由 #14 与 #16 跟踪。

Implementation began on 2026-11-10 with typed TCP outcomes and the bounded process adapter. The implementation record above describes the code, compatibility and local verification; #14 and #16 continue to track full acceptance.

后续实现为连接和监听端口页面加入显式采集结果与部分数据状态，实施记录见上表；本次更新纳入 PR #20。

A subsequent implementation adds explicit collection results and partial-data states to Connections and Listeners. Its implementation record is linked above and included in the PR #20 update.

2026-11-11 的实现为 ARP 和 Wi-Fi 系统采集增加显式结果状态，并修正不完整 ARP 邻居的解析。诊断页和 Dashboard 现在区分命令失败与空结果；Wi-Fi 未知格式会报告无法识别的输出行数，不推断空详情的原因。受控 UI 验收仍待完成。代码、测试结果和限制见上表记录；本次更新纳入 PR #20。

The 2026-11-11 implementation adds explicit result states for ARP and Wi-Fi collection and corrects incomplete-neighbor parsing. The diagnostics page and Dashboard distinguish command failures from empty results; unknown Wi-Fi output reports its unrecognized-line count without guessing why details are absent. Controlled UI acceptance remains open. The linked record documents the implementation, checks and limits; the work is included in the PR #20 update.

同日还修复了 IP 扫描器吞掉单目标初始化错误后丢失结果行的问题。测试通过注入失败，不访问外部目标；详情见 T03 实施记录。

The same day, the IP scanner was fixed to retain a target row when per-target setup fails. The deterministic test injects the error and contacts no external target; see the T03 implementation record.

后续实现为 IP/TCP 批次接入实时进度和运行中任务取消，保留停止前已完成的 IP 行。实现和 fixture 验证见 T03 批次记录；GUI 自动化与更广泛的 MCP 作业接入仍未完成。

A subsequent implementation adds live progress and in-flight task cancellation to IP/TCP batches and preserves IP rows completed before stop. See the T03 batch record for implementation and fixture checks; GUI automation and broader MCP job adoption remain open.

2026-11-11 的 T02 实现将系统 A/AAAA 解析与指定服务器的原始 DNS 查询分开，并去掉隐式公网 DNS 回退。IPv6 nameserver 解析和 MCP 回环检查已覆盖；VPN split DNS、`.local` 与多接口仍需单独验收。详情见上表双语记录；本次更新纳入 PR #20。

The 2026-11-11 T02 implementation separates system A/AAAA resolution from raw DNS queries to a specified server and removes the implicit public-DNS fallback. IPv6 nameserver parsing and MCP loopback checks are covered; VPN split DNS, `.local` and multiple interfaces remain to be accepted. See the bilingual record above; the work is included in the PR #20 update.

先处理 TCP/权限/依赖失败分类、系统解析与显式 DNS、Job 执行边界、Repository 与 SQLite 迁移，再交付一条 DNS → TCP → TLS/HTTP 的故障处理流程。真实设备互操作、数据升级、最低系统和正式公证作为持续验收项。

Start with typed failures, system resolution versus explicit DNS, Job execution boundaries, and Repository/SQLite migration. Then deliver one complete DNS → TCP → TLS/HTTP incident workflow. Real-device interoperability, data upgrades, minimum OS coverage and formal notarization remain ongoing acceptance work.

HTML 看板在 GitHub 文件页面只显示源码。下载该文件后用浏览器打开即可使用语言切换和优先级筛选；无外部依赖。GitHub 内直接阅读请使用 Markdown 清单。看板的同目录文档链接需要同时下载对应文档。

GitHub displays the HTML source. Download the file and open it in a browser to switch languages and filter priorities; it has no external dependencies. Use the Markdown backlog for reading on GitHub. Relative document links on the offline board require the corresponding files beside it.

JSON 保存任务 ID、优先级、估算、依赖、中英文标题与验收条件；Markdown、CSV 和 HTML 保持一致。所有条目的 proposed 状态仅记录计划，进展由跟踪议题的实现链接和验收证据确认。完整任务集不构成 90 天交付承诺。

JSON records task IDs, priorities, estimates, dependencies, and Chinese/English titles and acceptance criteria. Markdown, CSV and HTML stay aligned with it. The proposed status records the plan; implementation links and acceptance evidence in tracking issues establish progress. The full backlog is not a 90-day commitment.

## 跟踪议题 / Tracking issues

总跟踪 / Overall tracker: [macOS 下一阶段改进计划 / Next-stage macOS improvement plan](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/13)

| 任务 / Task | 议题 / Issue |
|---|---|
| T01 · 类型化 TCP/权限/依赖错误 / Typed TCP, permission and dependency failures | [#14](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/14) |
| T02 · 系统 resolver 与显式 DNS 分离 / System resolution and explicit DNS queries | [#15](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/15) |
| T03 · Job runtime 与有界进程适配器 / Job runtime and bounded process adapter | [#16](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/16) |
| T04 · Repository 与 SQLite 迁移 / Repository abstraction and SQLite migration | [#17](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/17) |
