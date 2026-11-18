# T04 默认工作区所有权 / Default-workspace ownership

日期 / Date: **2026-11-18 · Asia/Shanghai**

实施分支 / Implementation branch: `codex/t04-workspace-ownership` · [T04 #17](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/17) · [总跟踪 / Overall #13](https://github.com/Nevergoodstudy/NETworkManager-macOS/issues/13)

[计划索引 / Plan index](README.md) · [任务与验收 / Backlog and acceptance](NEXT_GENERATION_BACKLOG_2026-11-09.md) · [SQLite 基础切片 / SQLite foundation](T04_SQLITE_FOUNDATION_2026-11-18.md)

## 中文

本轮修复默认资产工作区在多个实例之间的所有权问题。此前第二个 store 加载同一数据库时，可能把第一个实例尚未完成的 `running` 诊断当作遗留任务改为 `interrupted`；原实例后续提交还会发生 revision 冲突。现在，默认工作区在读取、首次建库、旧 JSON 迁移和启动恢复之前先取得独占所有权，未取得时直接报告工作区占用，不读取或改写资产数据。

这是改进计划的第九个实施切片，仍属于第一阶段 P0。九个切片覆盖 T01–T04（4/16 主项有实现），**0/16 主项满足全部验收**。T04 保持开放。此前 SQLite 基础已经通过 [PR #28](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/28) 于 2026-11-18 12:37:31 UTC 合并，merge 为 `55ad97b4ecc4663846072bc1c9cd5f9c2537fee6`；最终 HEAD `dba6168` 的 push [44303640423](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44303640423) 与 PR [44303647188](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44303647188) 中 macOS 15/26 的四个构建 job 均成功。仅 tag 触发的正式签名/公证 job 跳过；这些历史结果不能代替本轮提交的验收。

### 用户可见行为

- 第一个默认 `AssetStore()` 持有工作区，能够正常读取、修改资产、运行和保存诊断、导入及导出备份。
- 第二个实例的资产页显示工作区占用状态和重试入口。该 store 禁止读取数据、修改资产、启动/结束诊断、分页、导入和导出；它不会把占用误报为数据库损坏，也不会进入可以覆盖现有工作区的备份恢复流程。
- owner 退出后，原占用窗口可以重试并加载数据。若重试取得所有权后才发现数据库损坏，会清除先前的占用错误，进入正常损坏恢复流程，允许导入有效备份。
- owner 自己再次 `load()` 不会中断自己刚启动的诊断；只有首次成功载入工作区时才将遗留 `running` 记录恢复为 `interrupted`。从损坏状态成功导入后也会记录已载入状态，避免随后重载误中断新诊断。
- 所有权仅保护默认资产 SQLite 工作区。显式 JSON 路径保留 JSON adapter；显式 SQLite repository 默认保留原有事务与 revision 行为，可通过 `requiresExclusiveOwnership` 选择所有权保护。凭证秘密仍由 Keychain 保存，MCP 仍未隐式接入资产库。

### 锁与数据边界

`AssetWorkspaceOwnership` 使用数据库旁的稳定文件 `assets.sqlite.owner.lock`，以 `O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW` 和权限 `0600` 打开，再执行非阻塞 `flock(LOCK_EX | LOCK_NB)`。文件描述符由 repository 保留，直到 repository 销毁或进程退出；进程被 `SIGKILL` 结束时也由内核释放锁。`O_CLOEXEC` 避免执行外部程序后由存活的后代进程继续持有该描述符。

owner lock 不会被删除或替换，因此竞争者和后续接管者锁定相同 inode。目录创建失败、锁文件不可打开或被符号链接替代等情况分类为访问不可用，和锁正被占用、数据库内容损坏分别处理。普通读写、分页、数据库备份、普通导入与损坏恢复都在进入 repository 的文件锁操作时先检查所有权；原有短期文件锁、事务和 revision 检查继续保护提交。

启动状态写入稳定 stderr 标记，便于实际应用测试等待工作区状态，标记不包含数据路径或内容：

```text
[assets] workspace ready
[assets] workspace access blocked: in-use
[assets] workspace access blocked: unavailable
[assets] workspace recovery required
```

### 本轮验证状态

本机为 Apple Silicon M4 Pro（Mac16,8）、arm64、macOS 27.2.1。支持政策仍为所有 Apple Silicon M 系列 Mac、最低 macOS 14；本机结果不等于全部 M 系列型号均已实测。

<!-- T04_OWNERSHIP_VALIDATION_START -->
| 检查 | 结果与证据边界 |
|---|---|
| Debug `NMTest --storage-only` | 已通过；包含独立进程所有权及既有 SQLite/JSON 存储检查 |
| 完整 Release `NMTest` | 已通过；包含本轮所有权回归和既有核心检查，Release 测试为 `@testable` 启用 testability |
| `NMCheck` | 已通过；既有核心检查保留 |
| 独立 NMTest owner 子进程 | 已通过；通过默认 `AssetStore()` 创建真实持久化 `running` 记录，竞争者被阻止后 owner 能 finish 并保存；正常子进程退出后原 blocked store 可重试接管 |
| 崩溃、描述符和错误状态 | 已通过；`SIGKILL` 后恢复 interrupted、repository 销毁释放、原生 `posix_spawn` 后代存活时可接管、稳定 inode、目录为普通文件与符号链接锁分类、占用到损坏恢复、导入恢复后不误中断新任务 |
| 实际 `.app` / DMG | 已通过本轮重新构建与 LaunchServices 启动；thin arm64、深度严格签名、Info.plist、独立/内置/搬迁 MCP、DMG 完整性以及安装/替换升级/卸载全部通过，产物为 ad-hoc |
| 当前打包存储所有权检查 | 已通过；两个独立 `.app` 路径、占用时 snapshot/revision 不变、SIGTERM/SIGKILL 释放与接管、稳定锁 inode、Python 持锁期间 running 夹具不被恢复、释放后正常恢复及损坏 JSON 字节保护 |
| 实际 GUI 与菜单退出 | 已通过；原 owner 两次 Ping、占用窗口与禁用操作、菜单 Quit 释放锁、原 contender 重试接管、保留全部历史并再完成一次 Ping；数据库确认三个本轮 GUI Ping 成功结果 |
| 本轮远端 CI / GitHub 交付 | **待验收**；本轮分支的 CI 与合并状态需另行记录，不能沿用 PR #28 的结果 |
| 正式发布 | 未完成 Developer ID 签名、公证和 Gatekeeper gate；当前本机打包流程为 ad-hoc |
<!-- T04_OWNERSHIP_VALIDATION_END -->

`AssetWorkspaceOwnershipChecks.swift` 的进程是真正独立的 NMTest 子进程。它调用默认 `AssetStore` 和 `beginDiagnostic` / `finishDiagnostic`，并独立检查数据库 payload 和 revision；它没有执行实际网络诊断，也不证明 GUI 正在执行 Ping。测试覆盖首次建库和旧 JSON 迁移前占用时 SQLite 不发布、原 JSON 字节不变；覆盖 repository 与 store 全部受保护入口拒绝访问，确保 owner 的记录和 revision 不变。

`test-packaged-storage.py` 使用两个临时独立 `.app` 路径，通过 LaunchServices 启动，使用同一隔离 support 目录验证竞争，再用独立目录验证损坏数据。脚本检查实际应用进程持有 owner-lock 描述符。其用于启动恢复的 `running` 是持久化夹具，包含 Python 持锁期间启动应用的场景，不是 owner GUI 正在运行的网络任务。脚本的 SIGTERM 接管不等于用户通过应用菜单正常退出。

本轮 GUI 使用同一隔离 support 目录的两个独立应用副本：2026-11-18 20:49:37（Asia/Shanghai）首次 Ping 127.0.0.1 成功；竞争实例明确显示占用后，owner 于 20:53:34 再次成功并保存。通过应用菜单退出 owner 后，独立进程与 `flock` 检查确认锁释放；原占用窗口点击重试加载全部四条历史，20:54:39 又完成一次 Ping，共五条历史（其中三条为本轮真实 GUI 成功 Ping，另两条为原 fixture）。最后通过菜单退出接管实例并确认锁空闲。三个 Ping 均显示约 0.1 ms；未用持久化 running 夹具冒充正在执行的网络诊断。

产物为 `dist/macos/NETworkManager.app` 与 `dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg`，版本沿用资源中的 `2026.11.17.0`。测试日志保存在本机 `/tmp/networkmanager-ownership-*.log`，覆盖 Release、MCP、package、packaged-storage 与 DMG lifecycle；临时日志不是跨机器持久化发布凭据。

### 剩余验收

- 真实 GUI 网络诊断仍在执行时启动第二 GUI 的竞争场景尚待验收。本轮已验证占用窗口存在时 owner 能完成 Ping、菜单正常退出、原 contender 重试接管及继续诊断；NMTest 子进程和持久化夹具不替代活跃网络场景。
- 真实满盘、权限拒绝、迁移和恢复关键步骤 kill、异常退出后的数据保护矩阵尚未全部完成；目录普通文件与 symlink fixture 只覆盖对应错误分类。
- store/UI 仍保留完整快照并同步等待提交；异步调用边界和历史分页 UI 尚未完成。SQLite 基础记录中的性能结果衡量 repository，不代表界面响应性能。
- T01–T03 的受控 UI、VPN split DNS、`.local`、IPv6-only、多接口、权限与 runtime 生命周期矩阵仍开放；T15 最低系统、真实设备和正式发布，以及 T16 严格并发工作也继续开放。

## English

This slice protects ownership of the default asset workspace. Previously, a second store loading the same database could mark the first instance's active `running` diagnostic as `interrupted`, followed by a revision conflict when the original instance saved. Default-workspace ownership is now acquired before reads, bootstrap, legacy JSON migration and startup recovery. A contender reports workspace occupancy without reading or changing asset data.

This is the ninth implementation slice in the first P0 stage. Nine slices cover T01–T04 (4/16 main tasks have implementation), with **0/16 fully accepted**. T04 remains open. The SQLite foundation was merged through [PR #28](https://github.com/Nevergoodstudy/NETworkManager-macOS/pull/28) at 2026-11-18 12:37:31 UTC as `55ad97b4ecc4663846072bc1c9cd5f9c2537fee6`. Its final HEAD `dba6168` passed all four macOS 15/26 build jobs in push run [44303640423](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44303640423) and PR run [44303647188](https://github.com/Nevergoodstudy/NETworkManager-macOS/actions/runs/44303647188). Tag-only formal signing/notarization jobs were skipped. Those historical results do not establish acceptance of this ownership code.

### Behavior and implementation

The first default `AssetStore()` owns the workspace and can use asset records, diagnostics and backup import/export. A second asset window displays workspace occupancy and a retry action. Its facade rejects asset reads and changes, diagnostic begin/finish, pagination, import and export. Occupancy does not become a database-corruption error or enable recovery that could replace a live owner's data.

After the owner exits, the blocked window can retry without being recreated. If that retry acquires ownership but then encounters a damaged database, the stale access error is cleared and normal backup recovery becomes available. Only the first successful workspace load recovers unfinished runs: an owner reloading its own store preserves its active diagnostic. Successful recovery import also records that the workspace has loaded, so a later reload cannot interrupt its new run.

The default SQLite asset workspace receives this protection. Explicit JSON paths retain the JSON adapter; explicit SQLite repositories retain existing transaction/revision behavior by default and can opt into `requiresExclusiveOwnership`. Credential secrets remain in Keychain and MCP gains no implicit asset access.

`AssetWorkspaceOwnership` opens the stable sibling file `assets.sqlite.owner.lock` with `O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW`, mode `0600`, then takes nonblocking `flock(LOCK_EX | LOCK_NB)`. The repository retains its descriptor until destruction or process exit; the kernel also releases it after `SIGKILL`. `O_CLOEXEC` prevents an executed descendant from retaining ownership after the owner exits. The file is never deleted or replaced, so contenders and successors use the same inode.

Directory/open/symlink failures report unavailable access, separately from lock contention and damaged database contents. Every protected repository load, save, page, database backup, normal restore and damaged restore acquires ownership before its existing file-lock operation. Short-lived file locking, transactions and revision checks continue to protect commits. Stable stderr markers above report readiness, contention, unavailable access or required recovery without paths or asset payloads.

### Validation status and boundaries

Local Debug storage checks, full Release `NMTest` and `NMCheck` passed on Apple M4 Pro (Mac16,8), arm64, macOS 27.2.1. Release NMTest enables testability for existing `@testable` imports. The current arm64 `.app` / DMG passed rebuild and LaunchServices startup, strict deep signature and Info.plist checks, independent/bundled/relocated MCP, DMG integrity and install/replace-upgrade/uninstall validation. Packaged ownership checks also passed for two actual app paths, unchanged blocked snapshot/revision, SIGTERM/SIGKILL release and takeover, stable lock inode, Python-held-lock recovery protection and corrupt JSON preservation. **This branch's remote CI/delivery remains pending.** Local package workflows are ad-hoc; Developer ID, notarization and Gatekeeper acceptance remain open. Support still covers all M-series Apple Silicon Macs from macOS 14, but one local machine is not an all-model test matrix.

Independent NMTest processes create a default `AssetStore`, call `beginDiagnostic` to persist a real `running` record, and finish/save it after contender rejection. Checks cover contention before bootstrap and migration, exact original JSON-byte preservation, unpublished SQLite while blocked, every protected repository/store operation, unchanged owner payload/revision, owner reload, normal child-process exit and retry takeover, SIGKILL recovery persisted as interrupted, repository destruction, native `posix_spawn` descendants still alive after owner exit, stable lock inode, unavailable paths/symlinks, blocked-to-corrupt recovery and reload after recovery import. These child processes execute storage APIs, not actual network diagnostics or a GUI Ping.

The packaged script uses two temporary independent `.app` paths, launches them through LaunchServices and shares an isolated support directory for contention; damaged-data checks use separate isolated support. It checks that the application process holds the lock descriptor. Its persisted `running` records are fixtures, including a case launched while Python holds the lock. They are not evidence of an active owner GUI network diagnostic. SIGTERM takeover is separate from a user quitting through the app menu.

Actual GUI checks passed occupancy and disabled add actions, two owner loopback Pings (including one with the contender open), normal menu quit and verified lock release, retry takeover without recreating the blocked window, preserved history and one successor Ping. Database verification found all three new successful GUI Ping records. Both isolated apps then exited through the menu and released ownership. Acceptance still needs launching a contender while an actual GUI network diagnostic is executing; physical disk-full/permission and killed-migration/restore matrices; asynchronous store/UI integration and history pagination; remaining T01–T03 platform/runtime gates; minimum-system and real-device coverage; formal T15 release gates; and T16 concurrency work. Repository performance measurements in the foundation record do not establish GUI responsiveness.

## 复现入口 / Reproduction entrypoints

以下为验收入口，不表示全部命令已在本轮通过；结果以本页状态表为准。按顺序运行，所有应用测试使用临时 support 目录，避免触碰真实用户资产。

These are validation entrypoints, not a claim that every command has passed for this slice. Run sequentially and use temporary support directories; the status above records completed checks.

```bash
swift run --package-path macos NMTest --storage-only
swift run --package-path macos -c release -Xswiftc -enable-testing NMTest
swift run --package-path macos NMCheck
NETWORKMANAGER_SUPPORT_DIRECTORY="$(mktemp -d /tmp/networkmanager-ownership-app.XXXXXX)" CREATE_DMG=1 ./script/build_and_run.sh --verify
python3 macos/Scripts/test-packaged-storage.py --app dist/macos/NETworkManager.app
codesign --verify --deep --strict dist/macos/NETworkManager.app
plutil -lint dist/macos/NETworkManager.app/Contents/Info.plist
hdiutil verify dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg
./macos/Scripts/verify-dmg-lifecycle.sh dist/macos/NETworkManager-macOS-2026.11.17.0-arm64.dmg
```

## 实现入口 / Implementation references

- [Workspace access errors and lifetime lock](../Sources/NMCore/AssetWorkspaceOwnership.swift)
- [Repository ownership before file operations](../Sources/NMCore/SQLiteAssetRepository.swift)
- [Default-store access states and recovery transitions](../Sources/NMCore/Assets.swift)
- [Assets occupancy and retry interface](../Sources/NMAssets/AssetsView.swift)
- [Localized access messages](../Sources/NMCore/Localization.swift)
- [Independent owner-process checks](../Sources/TestRunner/AssetWorkspaceOwnershipChecks.swift)
- [Storage-suite entrypoint](../Sources/TestRunner/AssetRepositoryChecks.swift)
- [Actual packaged-app ownership checks](../Scripts/test-packaged-storage.py)
