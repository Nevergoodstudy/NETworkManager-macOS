# T01 ARP 与 Wi-Fi 系统采集 / ARP and Wi-Fi system collection

日期 / Date: 2026-11-11

本地分支 / Local branch: `codex/socket-inventory-local`
交付范围 / Scope: T01 系统采集状态切片 / T01 system inventory result-state slice

[计划索引 / Plan index](README.md) · [连接与监听端口 / Connections and listeners](T01_SOCKET_INVENTORY_2026-11-10.md)

## 中文

本批代码和 fixture 已纳入 PR #20 的实现更新；受控 UI 验收和不同系统版本的字段检查仍待完成。

ARP 邻居表和 Wi-Fi 摘要原先只返回数组，命令失败会变成空列表。新结果保留解析后的记录、状态、稳定问题代码和 `CommandResult`；`collect()` 是异步入口，`collectSync()` 提供阻塞兼容边界。旧 `NeighborTable.list()` 与 `WiFiInventory.current()` 仍可用，供其他兼容调用者使用。

结果状态分为 `loaded`（有记录）、`empty`（成功且无记录）、`partial`（有记录但伴随警告或解析问题）、`unavailable`（没有可用记录并存在命令问题）和 `limited`（命令成功，但本次请求的字段没有提供）。问题代码涵盖命令缺失、启动权限或其他启动失败、执行失败、超时、取消、输出截断、清理不完整、stderr 提示、无法识别的 ARP 记录及字段不可用。错误类型不通过 stderr 文案猜测权限。

解析器现在识别 `at (incomplete)` 邻居：保留地址、接口与 `Incomplete` 状态，不把占位文本当作 MAC 地址或标成 `Reachable`。非空但无法解析的 ARP 行计入无法识别记录；有效行仍显示为部分结果。

Wi-Fi 查询继续使用 `system_profiler SPAirPortDataType -detailLevel mini`。macOS 本机 `system_profiler -usage` 说明 mini 报告不包含可识别个人信息。本机输出只给出 Wi-Fi 区段和接口名，没有当前网络详情；这不足以判断原因是未连接、系统省略字段还是其他情况，因此状态保留为成功空结果，不再断言 mini 级别省略了 SSID/BSSID。成功但非空且无法识别的输出则标为不可用，并在详情中显示无法识别的输出行数。当前查询不改为收集更详细、可能包含网络标识的数据。若要恢复完整 Wi-Fi 字段，应单独评估 CoreWLAN 的 API、授权和隐私行为。

系统诊断页已迁移 ARP 和 Wi-Fi 到异步结果 API，呈现加载、取消、空结果、部分结果及命令失败状态；空态文案与采集状态一致。Dashboard 的套接字和邻居列表也改为读取 typed result：采集失败不再显示为 `0`/无记录；incomplete 邻居显示为未完成状态，不再使用代表可达的绿点。详情折叠区展示退出码、无法识别的输出行数和 stderr；状态对象继续保留完整命令证据。取消使用共享进程运行时终止当前采集。Connections/Listeners 的取消按钮保留原可访问标识，其他系统采集使用通用标识。

### 本机验证

- arm64、macOS 27.2.1（26B131）、Apple Swift 6.4.2；Swift 5 语言模式与 macOS 14 最低版本未变。
- `swift run --package-path macos NMTest`：全部检查通过，包括 incomplete ARP、empty/failure/partial 状态、Wi-Fi 空输出与未知格式分类，以及本机 ARP 与 `system_profiler` 适配器调用。
- `swift run --package-path macos NMCheck`：通过。
- `swift build --package-path macos --product NETworkManagerMac`：Debug 应用目标构建通过，包含 NMUtilities 和 NMDashboard SwiftUI 页面。
- `git diff --check`：通过。
- SwiftPM 输出包含已有的 CommandLineTools framework/library 搜索路径告警；本次构建与测试成功。

本批未做 UI 自动化或受控慢查询切换/取消验收。MCP 当前没有 ARP/Wi-Fi 列表调用；其他仍使用兼容数组 API 的调用者尚未逐一清理。签名身份下的 Local Network 权限矩阵、CoreWLAN 字段能力、其他系统版本、正式签名、公证和 Gatekeeper 仍未验证。不能据此把 T01 标为验收完成。

## English

This implementation and its fixtures are included in the PR #20 update. Controlled UI checks and field coverage across supported macOS versions remain open.

ARP neighbors and Wi-Fi summaries previously returned arrays only, so command failures appeared as empty lists. The new result retains parsed rows, a state, stable issue codes, and the original `CommandResult`. `collect()` is the asynchronous entry point; `collectSync()` is the blocking boundary. The legacy `NeighborTable.list()` and `WiFiInventory.current()` APIs remain available for other compatibility callers.

States are `loaded`, `empty`, `partial`, `unavailable`, and `limited`. The issue vocabulary covers a missing command, launch permission or other launch failure, execution failure, timeout, cancellation, output truncation, incomplete cleanup, stderr warnings, unrecognized ARP records, and unavailable fields. Permission types are never inferred from stderr wording.

The parser now recognizes an `at (incomplete)` neighbor. It retains the address, interface and `Incomplete` state without treating the placeholder as a MAC address or marking it `Reachable`. Non-empty ARP lines that cannot be parsed are counted, while valid rows remain visible as a partial result.

Wi-Fi collection still runs `system_profiler SPAirPortDataType -detailLevel mini`. The local `system_profiler -usage` help says mini reports contain no identifying personal information. On this machine the output contained Wi-Fi section and interface headings, but no current-network details. That is insufficient to determine whether the Mac is disconnected, the system omitted fields, or another condition applies, so the result remains a successful empty result; the UI no longer claims that mini detail removed SSID/BSSID. Successful non-empty output that the parser cannot recognize is reported as unavailable with a count of unrecognized output lines. The query does not switch to collecting more detailed data that may identify a network. Restoring complete Wi-Fi fields requires a separate review of CoreWLAN APIs, authorization and privacy behavior.

The System Diagnostics page now uses the asynchronous ARP and Wi-Fi result APIs and shows loading, cancellation, empty, partial and command-failure states. Empty-state wording follows the collection state. Dashboard socket and neighbor panels also consume typed results: collection failures no longer appear as zero/no records, and an incomplete neighbor is labeled as incomplete instead of receiving a green reachability indicator. The diagnostics disclosure shows the exit status, unrecognized-output line count and stderr; the result object retains complete command evidence. Cancellation terminates the active collection through the shared process runtime. Connections and Listeners retain their existing accessibility identifier; other system collection uses a general identifier.

### Local verification

- arm64, macOS 27.2.1 (26B131), Apple Swift 6.4.2; Swift 5 language mode and the macOS 14 minimum are unchanged.
- `swift run --package-path macos NMTest`: all checks passed, including incomplete ARP parsing, empty/failure/partial states, Wi-Fi empty and unrecognized-output classification, and live local ARP and `system_profiler` adapter calls.
- `swift run --package-path macos NMCheck`: passed.
- `swift build --package-path macos --product NETworkManagerMac`: the Debug app target built, including the NMUtilities and NMDashboard SwiftUI pages.
- `git diff --check`: passed.
- SwiftPM emitted existing CommandLineTools framework/library search-path warnings; the build and tests succeeded.

This batch did not run UI automation or controlled slow-query cancellation/switching checks. MCP has no ARP/Wi-Fi list call; remaining callers that use compatibility array APIs have not all been reviewed. The signed-identity Local Network permission matrix, CoreWLAN field coverage, other macOS versions, formal signing, notarization and Gatekeeper remain unverified. T01 has not met its full acceptance criteria.
