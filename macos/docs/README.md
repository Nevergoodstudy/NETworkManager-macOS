# macOS 改进计划 / macOS improvement plan

研究日期 / Research date: **2026-11-09** · 文档修订 / Documentation revision: **2026-11-10**

**待实施提案。** 方案审阅的源码是 [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8)，包含 [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12) 中待合并的 MCP 与界面改动。方案文档独立提交；其中列出的已有能力应对照该提交阅读，不能视为 main 或正式发行版的功能承诺。

**Proposed work.** The reviewed source is [0944345d73df](https://github.com/Nevergoodstudy/NETworkManager-macOS/tree/0944345d73df0eafb2e7353aecca48d924398de8), including MCP and UI changes awaiting review in [PR #12](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/12). This documentation is submitted separately. Existing capabilities described in the proposal refer to that commit; they are not a statement that the same features have reached main or a release.

| 内容 / Material | 入口 / Entry |
|---|---|
| 中文架构与实施方案 | [阅读全文](NEXT_GENERATION_RESEARCH_2026-11-09.zh-CN.md) |
| English architecture and implementation proposal | [Read the proposal](NEXT_GENERATION_RESEARCH_2026-11-09.en.md) |
| 16 项任务、依赖、估算与验收 / 16 tasks, dependencies, estimates and acceptance | [双语任务清单 / Bilingual backlog](NEXT_GENERATION_BACKLOG_2026-11-09.md) |
| 表格导入 / Spreadsheet import | [Bilingual CSV](NEXT_GENERATION_BACKLOG_2026-11-09.csv) |
| 机器可读任务 / Machine-readable tasks | [JSON, schemaVersion 2](NEXT_GENERATION_BACKLOG_2026-11-09.json) |
| 交互路线看板 / Interactive roadmap | [Offline HTML](NEXT_GENERATION_ROADMAP_2026-11-09.html) |

先处理 TCP/权限/依赖失败分类、系统解析与显式 DNS、Job 执行边界、Repository 与 SQLite 迁移，再交付一条 DNS → TCP → TLS/HTTP 的故障处理流程。真实设备互操作、数据升级、最低系统和正式公证作为持续验收项。

Start with typed failures, system resolution versus explicit DNS, Job execution boundaries, and Repository/SQLite migration. Then deliver one complete DNS → TCP → TLS/HTTP incident workflow. Real-device interoperability, data upgrades, minimum OS coverage and formal notarization remain ongoing acceptance work.

HTML 看板在 GitHub 文件页面只显示源码。下载该文件后用浏览器打开即可使用语言切换和优先级筛选；无外部依赖。GitHub 内直接阅读请使用 Markdown 清单。看板的同目录文档链接需要同时下载对应文档。

GitHub displays the HTML source. Download the file and open it in a browser to switch languages and filter priorities; it has no external dependencies. Use the Markdown backlog for reading on GitHub. Relative document links on the offline board require the corresponding files beside it.

JSON 保存任务 ID、优先级、估算、依赖、中英文标题与验收条件；Markdown、CSV 和 HTML 保持一致。所有条目的 proposed 状态仅记录计划，进展由跟踪议题的实现链接和验收证据确认。完整任务集不构成 90 天交付承诺。

JSON records task IDs, priorities, estimates, dependencies, and Chinese/English titles and acceptance criteria. Markdown, CSV and HTML stay aligned with it. The proposed status records the plan; implementation links and acceptance evidence in tracking issues establish progress. The full backlog is not a 90-day commitment.

<!-- tracking-links -->
