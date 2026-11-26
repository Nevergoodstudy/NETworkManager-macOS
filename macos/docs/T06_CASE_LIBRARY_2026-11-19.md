# T06：持久化 Case/Observation 本地事件库

**日期：2026-11-19** · 当前工作区增量，未提交或合并。按先完成本批功能、最后集中验证的顺序开发。

[现场计划](FIELD_ENGINEERING_PLAN.md) · [前批接口与事件检索](T05_T06_NETWORK_SEARCH_2026-11-19.md) · [工程清单](NEXT_GENERATION_BACKLOG_2026-11-09.md)

## 实现与操作

进入「现场工程 → 现场项目 → 本地事件库」，显式选择已保存的 `.nmfieldproject` 文件导入。来源列表可查看文件名、导入时间及观测总数，单独刷新某个来源，或经界面确认移除本地副本。源文件不会被导入、刷新或移除操作改写。关闭应用后，仍可离线查询已导入快照；未保存编辑需先保存到源项目，再刷新来源。文件移动或改名按新来源处理，原来源可手动移除。不会扫描目录或自动读取其他项目。

原有「检索项目事件」仍是窗口内会话检索。两种检索复用过滤与详情视图。详情展示保存的源文件名、快照时间、站点、工单、负责人、交接版本、设备快照、时间线及已保存复测引用。原文件可访问时可打开编辑；原文件丢失时本地快照仍能查看。

持久化使用独立 `field-cases.sqlite`，位于 `SettingsStore.supportDirectory`，遵循隔离支持目录环境变量。资产数据库的 schema、初始化与所有权逻辑保持原实现。共享 SQLite helper 仅放宽模块内可见性并增加有生命周期管理的行解码方法。

- `sources`：标准化文件 URL 主键、文件名、读取时间、版本令牌和完整校验后的项目快照。
- `cases`：来源 URL + 事件 UUID 复合键，索引状态、稳定设备身份、本地设备 UUID、创建时间和最新发生时间，保存折叠后的查询文本。
- `observations`：来源 + 事件 + 条目 UUID 复合键，保存发生时间和完整条目 payload，通过外键级联清理。证据和交接版本保留在来源项目快照中。

导入在后台读取，每批最多 40 个文件，每个最多读取 512 KB + 1 字节后校验；持久库最多 200 个来源。模型接口也重新执行完整项目解码校验。每个来源独立事务更新，坏文件不影响其他来源，刷新失败保留该来源旧数据。刷新时一次替换该来源及全部 Case/Observation，删除已不在源项目中的旧行。来源版本令牌拒绝旧窗口覆盖新数据或删除新副本。初始数据库采用暂存文件完成 schema 后再发布，检查 application_id/schema 后才打开可写连接，已初始化但丢失的库不会被静默重建。

查询按空白拆词并组合文本、状态、发生时间和设备条件。文本最多 2000 字符、100 个词；采用固定 POSIX locale 的 Unicode 大小写折叠和规范化，同步应用于会话与 SQLite 查询。SQL 参数绑定后用 `instr` 查找，不把 `%`、`_` 或引号解释成模式或 SQL。设备关联优先稳定外部身份，无外部身份的查询按本地 UUID；相同 IP 不足以建立关联。空时间线按创建时间匹配；其他按任一观测发生时间匹配。按最近发生时间倒序，再按来源和事件 UUID 排序；界面每页 25 个，模型允许 1–100 个。计数、分页和快照读取在同一读事务完成。

实现：[持久化模块](../Sources/NMCore/FieldCaseLibrary.swift) · [共享查询语义](../Sources/NMCore/FieldIncidentSearch.swift) · [事件库窗口](../Sources/NMAssets/FieldCaseLibraryView.swift) · [后台工作与窗口状态](../Sources/NMAssets/FieldCaseLibraryModel.swift) · [共享筛选与详情](../Sources/NMAssets/FieldIncidentSearchDetailView.swift) · [定向检查](../Sources/TestRunner/FieldCaseLibraryChecks.swift)

## 集中验证

2026-11-19 在功能实现后集中完成以下检查，未展开重复 DNS 深测：

| 检查 | 实际结果与范围 |
|---|---|
| `swift run --package-path macos -c release --disable-automatic-resolution -Xswiftc -enable-testing NMTest --next-development-only` | 通过；输出 `Case library: persistence, query, refresh, rollback, conflict, schema and limits passed` 与 `NMTest: next development checks passed`。覆盖数据库重新打开、源文件缺失、项目快照及观测恢复、会话/数据库 Unicode 查询一致性、设备身份、分页和上限、事务中途失败回滚、旧行清理、来源版本冲突、并发写者、移除级联和异常数据库保留。 |
| `macos/.build/release/NMTest --storage-only` | 通过；输出 `NMTest: storage checks passed`。回归共享 SQLite helper 的迁移、事务、分页、在线/WAL 备份、恢复与工作区所有权。 |
| `DIST_DIR=/private/tmp/nm-case-library-20261119.w4dwud/dist NETWORKMANAGER_SUPPORT_DIRECTORY=/private/tmp/nm-case-library-20261119.w4dwud/support script/build_and_run.sh --verify` | Release GUI 和 NMCP 构建通过；脚本确认 arm64-only 及内置代码架构、完成 ad-hoc 签名并确认隔离 App 进程仍在运行。GUI 构建约 45.75 秒，NMCP 约 32.16 秒。仅出现既有 CommandLineTools 缺失搜索目录的链接警告。 |
| 中文 GUI 简短检查 | 从「现场项目」进入本地事件库，显式导入合成 `maintenance-incidents.nmfieldproject`；显示 1 个来源、1 条观测和 1 个事件。选中后核对来源、快照时间、站点、负责人、工单 `SYNTH-20261119-01`、交接版本 1 和报障时间线。工单筛选保留 1 个结果，无匹配文本返回 0 个。关闭并重新打开事件库窗口，数据仍在；刷新来源更新快照时间并保持事件和观测计数。 |
| 静态检查 | `git diff --check`、新增本地化键覆盖和重复键检查、实施文档及计划内本地链接检查通过。 |

GUI 使用的合成源文件为 `/private/tmp/nm-next-slices-20261119-7vjljtts/fixtures/maintenance-incidents.nmfieldproject`。应用包位于 `/private/tmp/nm-case-library-20261119.w4dwud/dist/NETworkManager.app`，支持目录为 `/private/tmp/nm-case-library-20261119.w4dwud/support`；未操作客户网络。自动检查验证了源文件不在时数据库重开和移除副本保留源文件；本次 GUI 检查没有重新启动整个应用、删除副本或覆盖全套筛选与分页路径，不将这些路径计为 GUI 验收通过。

## 官方研究依据

2026-11-19 调用网络搜索/打开能力未返回可用正文，随后通过 Python HTTPS 并行读取以下官方 SQLite 文档并缓存到 `/private/tmp/nm-case-library-20261119-research/`：

- [Transactions](https://www.sqlite.org/lang_transaction.html)：用 `BEGIN IMMEDIATE` 开始写事务，失败时回滚。客户端仍需处理其他写者导致的 busy。
- [Isolation](https://www.sqlite.org/isolation.html)：WAL 读事务的快照隔离；本模块将计数、页面和项目快照放在同一读事务，刷新用事务提交。
- [Expressions](https://www.sqlite.org/lang_expr.html)：默认 `LIKE` 的大小写行为仅覆盖 ASCII，因此在 Swift 中统一 Unicode 文本折叠后用绑定的 `instr` 条件。

这些是当日读到的官方资料；本批结果来自本机 SQLite 和合成文件，不能替代所有系统版本或现场数据验收。

## 范围与后续

本地事件库保存明文项目副本及索引，沿用项目资料的客户批准本地存储要求；文件权限设为仅当前用户读写，移除副本不声称完成介质安全擦除。当前实现没有 FTS、任意附件库、独立 Case 编辑或 MCP Case 接口。

T06 接下来继续独立 TLS/HTTP 阶段与巡检模板，完整服务诊断链和导出仍待完成。受控 LAN/VPN、真实 NetBox、最低 macOS、Apple 签名权限和正式分发矩阵继续单独验收，不以反复 DNS 深测阻塞后续开发。工作区仍覆盖 T01–T06 的 6/16 主项部分实现，0/16 整项验收完成。
