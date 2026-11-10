# macOS 改进计划 / macOS improvement plan

研究日期 / Research date: **2026-11-09** · 文档修订 / Documentation revision: **2026-11-10**

**待实施提案。** 方案审阅的源码是 [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8)，该功能提交于 2026-11-10 通过 [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12) 合并进 `main`。文中所列已有能力以该源码基准为准，不代表已完成真实设备互操作或正式签名公证发布。

**Proposed work.** The reviewed source is [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8), merged into `main` through [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12) on 2026-11-10. Existing capabilities in the proposal refer to that baseline; they do not establish live-device interoperability or a formally signed and notarized release.

| 内容 / Material | 入口 / Entry |
|---|---|
| T01 TCP 与 T03 进程适配器实施记录 / TCP and process adapter implementation | [双语实施与验证记录 / Implementation and validation](T01_T03_IMPLEMENTATION_2026-11-10.md) |
| 中文架构与实施方案 | [阅读全文](NEXT_GENERATION_RESEARCH_2026-11-09.zh-CN.md) |
| English architecture and implementation proposal | [Read the proposal](NEXT_GENERATION_RESEARCH_2026-11-09.en.md) |
| 16 项任务、依赖、估算与验收 / 16 tasks, dependencies, estimates and acceptance | [双语任务清单 / Bilingual backlog](NEXT_GENERATION_BACKLOG_2026-11-09.md) |
| 表格导入 / Spreadsheet import | [Bilingual CSV](NEXT_GENERATION_BACKLOG_2026-11-09.csv) |
| 机器可读任务 / Machine-readable tasks | [JSON, schemaVersion 2](NEXT_GENERATION_BACKLOG_2026-11-09.json) |
| 交互路线看板 / Interactive roadmap | [Offline HTML](NEXT_GENERATION_ROADMAP_2026-11-09.html) |

2026-11-10 开始实施 T01 的 TCP 结果语义和 T03 的进程适配器切片，代码、兼容性和本机验证见上表实施记录；两项完整验收继续由 #14 与 #16 跟踪。

Implementation began on 2026-11-10 with typed TCP outcomes and the bounded process adapter. The implementation record above describes the code, compatibility and local verification; #14 and #16 continue to track full acceptance.

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
