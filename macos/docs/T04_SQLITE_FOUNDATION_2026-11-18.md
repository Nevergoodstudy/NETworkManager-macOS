# T04 Repository 与 SQLite 基础 / Repository and SQLite foundation

日期 / Date: **2026-11-18 · Asia/Shanghai**

交付分支 / Delivery branch: `codex/t04-sqlite-foundation` · [PR #28](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/28) · [T04 #17](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/17) · [总跟踪 / Overall #13](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/13)

[计划索引 / Plan index](README.md) · [原任务与验收 / Backlog and acceptance](NEXT_GENERATION_BACKLOG_2026-11-09.md) · [此前打包验收 / Previous package validation](APPLE_SILICON_VALIDATION_2026-11-18.md)

## 中文

本轮为 T04 建立可替换的 Repository 接口，将默认资产存储从整份 JSON 改为 SQLite，并保留现有资产、诊断记录和用户备份格式。此前 T01–T03 的七个切片已通过 PR #20 合并，Apple Silicon 打包与界面修复已通过 PR #27 合并。本轮新增第八个实施切片，覆盖主项增至 T01–T04（4/16），**整项验收仍为 0/16**。当前仍处于计划的第一阶段 P0 实施。

### 行为与兼容

- 默认数据文件改为 `~/Library/Application Support/NETworkManager/assets.sqlite`。已有 `assets.json` 在第一次 SQLite 启动时读取并验证；临时库导入后重新读取，确认全部字段、关系和数组顺序一致，再发布正式数据库。原 JSON 字节保留，不删除、不覆盖。
- 已初始化的 SQLite 是后续唯一资产数据来源。损坏数据库、未知版本、初始化后丢失的数据库和中断恢复标记会进入显式恢复流程，不自动回退到陈旧 JSON，也不重新种入默认工作区。
- 现有用户备份仍是 `formatVersion: 1` 的 ISO8601 JSON。导入先验证关系并持久化成功，再替换界面数据；恢复损坏存储时保留原数据库及存在的 WAL、SHM、journal 文件副本。
- 显式传入 `.json` 路径的调用使用 JSON adapter，保留既有 fixtures 与此类调用的读写行为。旧 JSON 读取同时支持 ISO8601 与数字日期；默认迁移保留数字日期中的子秒。
- 资产删除、子网解除设备关联、站点/工作区删除关联记录，以及重启后将未结束诊断标记为 `interrupted` 的既有行为保留。凭证秘密继续位于 Keychain；资产只持有 credential reference ID。
- MCP 没有隐式接入资产库。MCP 集成测试对 JSON 和 `assets.sqlite` 相关文件执行无新增、无修改检查。

### 存储接口与数据保护

`AssetRepository` 提供读取、保存、恢复与诊断分页；`AssetStore` 保留现有界面调用方式。JSON 和 SQLite adapters 使用相同快照，SQLite 使用系统 `sqlite3`，没有新增第三方数据库依赖。

SQLite 的专用串行队列负责编码和 I/O；文件锁协调 repository 实例，事务内 revision 检查拒绝陈旧快照覆盖较新提交。写入在提交成功后返回，失败不更新 baseline/revision。数据库采用 WAL、`synchronous=FULL`、外键约束和延迟关系检查；增量比较只编码和 upsert 有变化的记录，不使用可能触发级联删除的父记录 `INSERT OR REPLACE`。

读取完整快照时检查数据库完整性、外键、重复 ID、跨站点子网、悬空关系，以及 SQL 关系列/时间列与记录 payload 的一致性。数据库身份与 schema version 先经只读连接检查，通过后才建立写连接。版本 1 之外的数据库拒绝打开，不尝试降级转换。

诊断分页按 `startedAt` 降序、UUID 升序稳定排序，支持全部、设备和工作区范围；每页限制为 1–500 行，offset 必须非负。分页接口返回记录时核对其设备/时间列与 payload。全量读取负责更完整的关系验证。

数据库级备份使用 SQLite online backup，包含仍在 WAL 中的已提交数据；备份临时目标切换为 DELETE journal 后才以不覆盖目标的方式发布，形成可独立打开的数据库文件。用户界面的 JSON 导出格式继续保留；新增 SQLite 备份接口不表示本轮新增了数据库文件导出界面。

### 验证与交付记录

本机环境：Apple Silicon M4 Pro（Mac16,8），arm64，macOS 27.2.1；Swift 5 语言模式、macOS 14 最低版本与 arm64 发布政策未变。既存 CommandLineTools 搜索路径告警未阻断构建。

<!-- T04_PACKAGE_VALIDATION_START -->
| 检查 | 本轮结果与范围 |
|---|---|
| `NMTest --storage-only` | 通过；迁移、字段/顺序保留、即时独立重载、分页、非法关系拒绝、事务回滚、revision 冲突与恢复 |
| WAL 与备份 fixtures | 通过；独立 SQLite reader 保持旧事务，确认非空 WAL 后提交新数据；在线备份独立重载包含最新提交。已有备份目的文件不被覆盖 |
| SQL 篡改 fixtures | 通过；单独修改关系字段或时间排序列后，全量读取拒绝不一致记录 |
| AssetStore 回归 | 通过；JSON 备份往返、诊断证据、未完成运行恢复、子网解除关联、站点删除和损坏后导入恢复 |
| Release 完整 `NMTest` | 通过；包含存储与既有诊断、DNS、采集、进程等回归 |
| `NMCheck` 与发布架构策略 | Debug `NMCheck`（含 SNMPv3 密码向量）和 arm64-only 架构策略检查通过 |
| 只读差异复核 | 前轮发现的关系字段一致性与只读版本预检已修复；复核未发现新的可复现阻断问题 |
| 独立及内置 MCP | 独立 Release MCP strict-pool 检查及发布包内置 MCP 集成均通过 |
| 当前源码 `.app` / DMG | `CREATE_DMG=1 ./script/build_and_run.sh --verify` 在隔离 `NETWORKMANAGER_SUPPORT_DIRECTORY` 下通过；产物为 `dist/macos/NETworkManager.app` 与 `dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg`，均 arm64-only、ad-hoc 签名 |
| `.app` 与 DMG 完整性/生命周期 | `codesign --verify --deep --strict`、Info.plist lint、`hdiutil verify` 及 `verify-dmg-lifecycle.sh` 均通过；生命周期覆盖安装、替换升级、内置 MCP、LaunchServices 启动及卸载 |
| 已打包应用存储验收 | `test-packaged-storage.py` 通过；覆盖完整迁移、原 JSON 字节保留、running 记录重启恢复、WAL/完整性/外键、重启 revision 一致和损坏 JSON 保护 |
| 实际 GUI 资产与 JSON 往返 | 导入 `/tmp/networkmanager-t04-ui-backup.json` 后工作区、站点、子网、设备、中文备注及原 DNS 历史显示正确；设备 `127.0.0.1` Ping 成功（约 0.1 ms），历史由 1 条增至 2 条。应用导出 `/tmp/networkmanager-t04-ui-export-2026-11-18.json`，并核实包含旧 DNS、新 `succeeded` Ping 和全部关系 |
| 签名/分发边界 | 当前本机包为 ad-hoc 签名；未进行 Developer ID 正式签名、公证或 Gatekeeper 发布验收 |
| 远端 CI / 合并 | 启动器修复提交 `19b18d1` 的 push [44298991143](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44298991143) 与 PR [44299000443](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44299000443) 均已通过 macOS 15/26 全部构建任务（2026-11-18 12:11:41 UTC 前完成）。PR #28 为 OPEN，尚未合并；后续提交须另行验证 |
<!-- T04_PACKAGE_VALIDATION_END -->

远端 CI 历史：`9d0c54b` 的四个 push/PR 与 macOS 15/26 组合中，两个完整通过、两个在 MCP launcher 检查超时；`e004816` 的 push run [44293122612](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44293122612) 中 macOS 15 通过，macOS 26 在 `check_launcher initialize` 4.120 秒后超时（进程存活、stderr 为空），相同提交的 PR run [44293135367](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44293135367) 两个完整 job 均通过。加入失败诊断的 `60947c6` 在 push run [44295706610](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44295706610) 和 PR run [44295715678](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44295715678) 的四个 job 均在架构检查失败：`lipo -archs` 返回非零，脚本吞掉错误后误走 SwiftPM 回退，被 warm-launch guard 以 exit 91 拒绝，NMCP 尚未启动。该工具失败与此前初始化超时是否同根因仍未证实。修复提交 `19b18d1` 改用 `LC_ALL=C /usr/bin/file -Lb`，检查工具 stdin 指向 `/dev/null`，精确接受 thin arm64；工具执行失败显式报错，启动现成二进制不再依赖开发目录选择。本机 M4 的完整 Release strict-pool MCP 在故意无效的 `DEVELOPER_DIR` 下通过，且隔离 Intel、arm64e、Universal 与脚本缓存均触发显式 arm64 重建，无效重建结果在执行前被拒绝。原 4 秒请求预算、30 秒套件期限和全部协议断言保留。修复提交 `19b18d1` 的 push [44298991143](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44298991143) 与 PR [44299000443](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44299000443) 的四个 macOS 15/26 job 已完整通过，覆盖架构策略、核心/协议/MCP、应用打包启动、DMG、搬迁后 MCP、SQLite 迁移重启以及安装/升级/卸载。正式签名与公证 job 因仅由版本标签触发而跳过。该结果确认此提交通过远端验收，但不能证明旧初始化超时与工具失败同根因；PR #28 尚未合并。

<!-- T04_BENCHMARK_START -->
### 规模基准

Release（`-O`，为既有 `@testable` imports 启用 testable modules）基准于 **2026-11-18 18:16:17 +08:00** 在 Apple M4 Pro（Mac16,8）、macOS 27.2.1（26B131）完成。fixture 为 **10,000 台设备、100,000 条诊断、每页 50 行**；每个范围先 warm up 5 次，再测 100 个分布在历史中的 offsets。

| 分页范围 | p50 | p95 | 最大耗时 |
|---|---:|---:|---:|
| 全部诊断 | 2.57 ms | 4.17 ms | 5.57 ms |
| 工作区诊断（含关联查询） | 47.94 ms | 89.18 ms | 92.82 ms |

首次写入为 **1,465.86 ms**，完整重载为 **798.23 ms**，单条更新为 **107.15 ms**。上述两个分页范围的实测 p95 均低于 200 ms；单条更新仍包括当前同步快照处理所需的工作。

结果只衡量本机 fixture 下的 Repository 查询和保存，不代表 GUI 响应速度，也不等同于真实用户数据集。界面仍保留全量数组，并同步等待存储提交；本次基准不完成这些界面验收。
<!-- T04_BENCHMARK_END -->

### 剩余验收与后续

下一切片优先治理默认主库的进程所有权：在加载、建库和启动恢复前取得独占所有权，未取得时独立提示工作区占用并拒绝保存及备份恢复。验收使用同一隔离 support 目录中的两个实际 `.app` 进程，确认第二实例不改写活跃诊断与 revision，第一实例仍可完成保存，并验证正常退出和 `SIGKILL` 后可重新取得所有权。

- 界面仍保留全量数组，当前保存仍同步等待队列提交；虽然变更行编码移到 repository 队列，主线程等待与全量快照比较仍需后续异步接口和 UI 接入改进。历史界面尚未使用分页。
- 写入失败已通过事务中途触发器验证；真实磁盘满、权限拒绝、迁移/恢复关键点进程被终止、异常退出后的完整矩阵仍待补充。遗留临时文件与恢复标记 fixtures 不等同于真实 kill-during-import 验收。
- 重复 GUI/store 实例的运行所有权仍未治理。另一个实例在活跃诊断期间 `load()`，可能将已有 `running` 记录视作遗留并改成 `interrupted`，随后原实例保存会发生 revision 冲突。本轮不宣称多个 GUI 同时写入已受支持。
- T01/T02 仍有受控 UI、VPN split DNS、`.local`、IPv6-only、多接口、系统字段和权限矩阵；T03 仍有更广泛 runtime 接入与生命周期验收。审计未发现必须在本轮修复的确定性生产运行时缺陷；未使用的 `Shell.streamLines` 后续单独清理。
- T15 的最低系统、真实设备互操作、Developer ID、公证和 Gatekeeper，以及 T16 严格并发迁移继续开放。当前本机、fixture 和 ad-hoc 包证据不能替代这些验收。

## English

This T04 slice introduces a replaceable Repository interface and switches default asset persistence from whole-document JSON to SQLite while retaining asset records, diagnostic history and the existing user backup format. The seven T01–T03 slices were merged in PR #20, followed by Apple Silicon package/UI fixes in PR #27. The eighth slice extends implementation coverage to T01–T04 (4/16 main tasks), with **0/16 whole tasks fully accepted**. The project remains in the first P0 stage.

### Behavior and compatibility

The default file is now `~/Library/Application Support/NETworkManager/assets.sqlite`. On first SQLite startup, legacy `assets.json` is decoded and validated, imported into a unique temporary database and read back for complete equality, including field values, relationships and array order. Only the verified database is published. The original JSON bytes remain intact.

Once initialized, SQLite is authoritative. Corrupt, unsupported, missing-after-initialization or incompletely restored databases require explicit recovery rather than fallback to stale JSON or automatic reseeding. The user-facing backup remains ISO8601 JSON with `formatVersion: 1`. Import persists validated data before replacing the in-memory state; damaged recovery preserves the original database and available WAL/SHM/journal files.

Explicit `.json` storage paths retain the JSON adapter. Legacy reads accept ISO8601 and numeric dates, including subsecond numeric dates. Existing deletion/detachment semantics, structured diagnostic evidence and unfinished-run recovery are retained. Secrets stay in Keychain; assets contain only credential reference IDs. MCP gains no implicit asset-repository access, and its integration guard checks both JSON and SQLite-related files for unexpected changes.

### Storage and safeguards

`AssetRepository` exposes load, save, restore and diagnostic pages. The existing `AssetStore` facade continues to serve the UI. Two adapters share `AssetSnapshot`; SQLite uses the system library without a new third-party database dependency.

A serial repository queue performs encoding and I/O. A file lock coordinates repository instances, while transactional revision checks reject stale overwrites. Writes return after commit; failed transactions leave the cached baseline/revision unchanged. WAL, `synchronous=FULL`, foreign keys and deferred relationships protect normal commits. Delta writes encode/upsert changed records, avoiding parent `INSERT OR REPLACE` operations that could erase children.

Full reads check database integrity, foreign keys, IDs, relationships and agreement between SQL relation/time columns and the record payload. A read-only identity/version preflight precedes opening a writable connection. Schema versions other than 1 are rejected without an attempted downgrade.

Pages sort by descending start time and ascending UUID, with all/device/workspace scopes, a 1–500 limit and nonnegative offset. Returned diagnostic rows are checked against their device/time columns; full reads perform broader relationship validation. SQLite online backup captures committed WAL pages and normalizes its temporary target to DELETE journal before non-overwriting publication as a standalone database. The public JSON export format remains unchanged; a new SQLite backup interface is not a new UI export flow.

### Validation and limits

Focused storage checks and full Release NMTest passed; Debug NMCheck and the arm64-only architecture policy passed on M4 Pro (Mac16,8), macOS 27.2.1. The standalone Release MCP strict-pool check and bundled MCP integration passed. Coverage includes exact legacy-byte preservation and complete migration equality, independently reloadable commits, stable scoped pages, invalid-record rejection, injected mid-transaction rollback/retry, incremental parent preservation, stale revision rejection, standalone and live-WAL backups, future-version/corruption refusal, interrupted-recovery markers and AssetStore backup/deletion/recovery contracts. Direct SQL relation/time tampering is rejected. A read-only review confirmed the consistency and read-only-preflight fixes without a new reproducible blocker. Existing toolchain search-path warnings were non-fatal.

The current Release package built and launched successfully with `CREATE_DMG=1 ./script/build_and_run.sh --verify` under an isolated `NETWORKMANAGER_SUPPORT_DIRECTORY`. `dist/macos/NETworkManager.app` and `dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg` are arm64-only and ad-hoc signed. Deep strict code-signature verification, Info.plist lint, `hdiutil verify` and `verify-dmg-lifecycle.sh` passed, including install, replacement upgrade, bundled MCP, LaunchServices launch and uninstall. `test-packaged-storage.py` passed packaged legacy migration, exact source JSON-byte preservation, interrupted `running` recovery, WAL/quick-check/foreign-key validation, revision consistency after relaunch and protection of damaged JSON data.

In the visible GUI, `/tmp/networkmanager-t04-ui-backup.json` imported with workspace, site, subnet, device, Chinese notes and prior DNS history displayed correctly. A device Ping to `127.0.0.1` succeeded at approximately 0.1 ms and history increased from one to two records. The app exported `/tmp/networkmanager-t04-ui-export-2026-11-18.json`; inspection confirmed the prior DNS record, the new `succeeded` Ping and all relationships. These local ad-hoc package checks do not establish Developer ID signing, notarization or Gatekeeper acceptance.

The current-batch Release (`-O`, with testable modules for existing `@testable` imports) benchmark completed at 2026-11-18 18:16:17 +08:00 on Apple M4 Pro (Mac16,8), macOS 27.2.1 (26B131). Its fixture uses 10,000 devices and 100,000 runs, 50-row pages, five warmups and 100 distributed offsets per scope. All-history pages measured p50/p95/max of 2.57/4.17/5.57 ms; workspace pages measured 47.94/89.18/92.82 ms. Both measured p95 values are below 200 ms. Initial import, full reload and single-row update measured 1,465.86, 798.23 and 107.15 ms respectively. These are repository measurements on a synthetic local fixture; they do not establish GUI responsiveness or real-user-dataset performance.

Remote CI history: two of the four push/PR and macOS 15/26 combinations passed at `9d0c54b`, with two launcher timeouts. At `e004816`, push run [44293122612](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44293122612) passed macOS 15 but timed out on macOS 26 in `check_launcher initialize` after 4.120 seconds (process alive, empty stderr); PR run [44293135367](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44293135367) passed both full jobs. At diagnostic commit `60947c6`, all four jobs in push run [44295706610](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44295706610) and PR run [44295715678](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44295715678) failed before NMCP started: `lipo -archs` returned nonzero, the launcher swallowed the error and attempted a SwiftPM fallback, and the warm-launch guard rejected it with exit 91. A shared cause with the earlier initialization timeouts remains unconfirmed. Fix commit `19b18d1` uses `LC_ALL=C /usr/bin/file -Lb` with inspector stdin redirected from `/dev/null`, accepts exactly thin arm64, and reports inspection-tool failure explicitly. Warm startup no longer depends on developer-directory selection. The full local M4 Release strict-pool MCP check passed with an intentionally invalid `DEVELOPER_DIR`; isolated Intel, arm64e, Universal and script caches requested explicit arm64 rebuilds, and an invalid rebuilt result was rejected before execution. The four-second request budget, 30-second suite deadline and protocol assertions remain. At fix commit `19b18d1`, all four macOS 15/26 jobs passed in push run [44298991143](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44298991143) and PR run [44299000443](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44299000443), completing by 2026-11-18 12:11:41 UTC. Each full job covers the architecture policy, core/protocol/MCP checks, packaged-app startup, DMG verification, relocated MCP, SQLite migration/relaunch and install/upgrade/uninstall. Formal signing and notarization jobs were skipped because they require a version tag. These runs establish remote acceptance of this commit, without proving a shared cause for the earlier initialization timeouts and inspection-tool failures. PR #28 remains OPEN and unmerged; later commits need their own checks.

The next slice prioritizes default-workspace process ownership before load, bootstrap and startup recovery. A competing instance must report workspace occupancy separately and reject saves and backup recovery. Two actual `.app` processes sharing an isolated support directory must prove that the competitor leaves the active run and revision unchanged, the owner can finish and save, and ownership can be reacquired after normal exit and `SIGKILL`.

The UI still retains full arrays and synchronously waits for commits. Delta encoding runs on the repository queue, but caller waiting and full-snapshot comparison remain; asynchronous UI integration and history pagination are future work. Trigger-injected failures and interrupted-state fixtures do not complete the physical-full-disk, permission, killed-migration/restore and abnormal-exit matrix. Duplicate writable GUI/store ownership is also open: loading another store during a live diagnostic can mark its run interrupted and cause revision conflict for the original writer.

Existing T01–T03 network/platform/controlled-UI/runtime gates remain open. The runtime audit found no deterministic production defect requiring a change in this slice; unused `Shell.streamLines` cleanup remains separate. Minimum-OS coverage, real devices, Developer ID/notarization/Gatekeeper and strict concurrency remain T15/T16 work. Fixture, local-arm64 and ad-hoc evidence does not complete those gates.

## 复现 / Reproduce

CI evidence for accepted launcher-fix commit `19b18d1` and the earlier failures is recorded above. Historical checks do not establish acceptance of a later commit.

Run sequentially from the repository root on an Apple Silicon Mac. Package checks use the current build and temporary support directories, leaving the operator's normal application data untouched:

```bash
swift run --package-path macos NMTest --storage-only
swift run --package-path macos NMTest
swift run --package-path macos NMCheck
python3 macos/Scripts/test-architecture.py
swift build --package-path macos --product NMCP -c release
NMCP_CONFIGURATION=release LIBDISPATCH_COOPERATIVE_POOL_STRICT=1 python3 macos/Scripts/test-mcp.py --server macos/.build/release/NMCP --launcher macos/Scripts/run-mcp.sh
swift run --package-path macos -c release -Xswiftc -enable-testing NMTest --storage-only
swift run --package-path macos -c release -Xswiftc -enable-testing NMTest --storage-benchmark /tmp/networkmanager-storage-benchmark.json
NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-t04-app.XXXXXX)" CREATE_DMG=1 ./script/build_and_run.sh --verify
codesign --verify --deep --strict dist/macos/NETworkManager.app
plutil -lint dist/macos/NETworkManager.app/Contents/Info.plist
python3 macos/Scripts/test-mcp.py --app dist/macos/NETworkManager.app
python3 macos/Scripts/test-packaged-storage.py --app dist/macos/NETworkManager.app
hdiutil verify dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg
./macos/Scripts/verify-dmg-lifecycle.sh dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg
git diff --check
```

For the build-and-launch check, set `NETWORKMANAGER_SUPPORT_DIRECTORY` to a new absolute temporary directory (for example, `NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-t04-app.XXXXXX)" CREATE_DMG=1 ./script/build_and_run.sh --verify`). `test-packaged-storage.py` copies the app to a temporary path and uses its own isolated support directories. The storage suite and benchmark create isolated temporary databases. The benchmark is optional and is not a machine-speed assertion in normal correctness checks. Release NMTest needs `-Xswiftc -enable-testing` for its existing `@testable` imports; distributable application builds do not need that option. The local package is ad-hoc signed and these commands do not perform notarization or Gatekeeper release acceptance.

## 实现入口 / Implementation references

- [Repository interface and JSON adapter](../Sources/NMCore/AssetRepository.swift)
- [SQLite migration, transactions, pages and backup](../Sources/NMCore/SQLiteAssetRepository.swift)
- [AssetStore integration and public backup format](../Sources/NMCore/Assets.swift)
- [Storage correctness fixtures](../Sources/TestRunner/AssetRepositoryChecks.swift)
- [Optional scale benchmark](../Sources/TestRunner/AssetRepositoryBenchmark.swift)
- [Packaged-app storage acceptance](../Scripts/test-packaged-storage.py)
- [MCP persistence guard](../Scripts/test-mcp.py)

Applied skills: codebase-design, swiftpm-macos and test-triage; build-run-debug and packaging-notarization support the separate packaged-artifact validation. The existing run/build entrypoints remain the application workflow.
