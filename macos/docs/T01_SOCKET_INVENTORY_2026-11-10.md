# T01 连接与监听端口采集 / Connections and listeners

日期 / Date: 2026-11-10  
基线 / Base: `541ec46ff975fe763f0081c306575b66f17a87e9`  
本地分支 / Local branch: `codex/socket-inventory-local`  
交付范围 / Scope: T01 的 SocketInventory 切片 / SocketInventory slice of T01

[计划索引 / Plan index](README.md) · [上一批实施记录 / Previous implementation](T01_T03_IMPLEMENTATION_2026-11-10.md)

## 中文

本批次只在本地实施和验证，未推送分支、创建或更新 PR，也未改动 GitHub 议题。

连接与监听端口页面原先调用返回数组的接口。只要 `lsof` 非零退出，接口就返回空数组，页面无法区分没有数据和采集失败。本次新增保留运行结果的接口，迁移这两个页面，并保留仪表板等旧调用者的兼容入口。

### 结果约定

`SocketInventory.collect(scope:includeUDP:timeout:cancellation:)` 是异步入口；`collectSync` 提供阻塞调用边界。结果包含筛选后的行、筛选前有效行数、稳定问题代码、无法识别的记录数，以及完整的 `CommandResult`。默认超时 10 秒，每条输出流最多保留 1 MiB，共用上一批实现的有界进程运行时；取消会传到运行时。

| 状态 | 页面含义 |
|---|---|
| `loaded` | 本次查询完成，有匹配行；不代表拥有全系统可见权限。 |
| `empty` | 本次查询完成，没有匹配的可见行。 |
| `partial` | 已读取有效行，但存在采集或分类问题；即使筛选后行数为零，也保持“不完整”。 |
| `unavailable` | 没有可用行，并且存在明确的采集问题。 |

问题代码区分：命令缺失、无权启动命令、运行时繁忙、其他启动失败、非零退出、超时、取消、输出截断、进程清理不完整、无法识别的输出、无法分类的 TCP 状态，以及命令报告的消息。原始退出码、两个输出流和运行证据继续保留。stderr 文本仅供查看，不作为权限类型的判断依据。

`lsof` 用退出码 1 表达多种情况。固定查询仅在 stdout、stderr 都完全为空，观察字节数均为零，且没有超时、取消、启动错误、截断、清理问题或终止信号时，才将退出码 1 解释为没有可见匹配项。只保留了空前缀，或输出只有空白字符，都不满足这个例外。

### 采集和解析

新调用固定执行系统路径 `/usr/sbin/lsof`，参数逐项传入：

```text
-n -P -i -F0pcuftPnT -Ts
```

机器格式用 NUL 结束字段、用 LF 结束进程或文件集合。进程字段记录 PID、未受默认 COMMAND 列宽限制的命令名和数字 UID；文件字段记录描述符、地址族、协议、端点和可用的 TCP 状态。IPv6 端点保留原样，仅用 `->` 分开本地和远端。

解析器只接纳已闭合、必需字段齐全的记录。未知字段和 `T` 字段族中的其他成员不影响有效行；重复的必需字段、重复状态和缺失字段会使对应记录被拒绝。截断的最后记录不会拼成一条看似有效的行。损坏的进程边界会清除身份上下文，后续描述符不能继承上一进程的 PID。相同快照中的相同行使用稳定 ID。

UDP 正常没有 TCP 状态。缺少状态或带有未知状态的 TCP 行在 `all` 范围中仍然可见；连接和监听端口范围无法可靠归类这些行，会省略它们并报告 `unclassifiedTCPState`，保持不完整状态。

`list()`、`listeners()`、`connections()` 继续返回数组，保留旧接口的有损行为。原 `parse(_:)` 列格式入口继续可用，但新查询不会在机器格式失败后自动猜测列格式。ARP、WiFi 采集与仪表板的结果状态迁移留待后续批次。

### 页面行为

页面提供加载提示和取消按钮。重新采集、切换工具和离开页面会取消旧刷新任务；请求 UUID 和当前工具共同限制结果写入，避免旧结果覆盖新页面。有效的部分结果继续显示；退出码、无法识别的记录数和有界 stderr 可在详情中查看。新增文案均有中文和英文版本。

页面始终说明“仅显示当前账户可见的套接字。macOS 可能隐藏其他进程的连接。”这一限制不能由退出码或空 stderr 排除。Apple 的 Darwin 采集实现会静默跳过一部分 `EPERM`/`ESRCH` 进程，所以成功结果不会被描述为完整的全系统清单，也不会从空结果推断本地网络权限拒绝。

### 本机验证

环境：arm64、macOS 27.2.1（26B131）、Apple Swift 6.4.2。包保持 Swift 5 语言模式和 macOS 14 最低版本。

- 定向检查：`swift run --package-path macos NMTest --socket-inventory-only`。
- 完整回归：`swift run --package-path macos NMTest`。
- 自检：`swift run --package-path macos NMCheck`。
- Debug 全产品构建，以及 `build-app.sh` 的 arm64 Release 应用和内置 MCP 构建。
- Release 应用的 deep/strict 签名校验和 Info.plist 检查。
- Release 应用内置 MCP 的完整集成检查，启用严格 cooperative executor；仅使用回环目标与临时支持目录。

定向检查覆盖有效空结果与退出码 1、各种启动失败、超时与取消、警告和部分数据、输出截断、清理不完整、缺失/未来 TCP 状态、IPv4/IPv6、UDP、含空格和中文的命令名、未知字段、重复字段、未闭合集合和错误 PID 归属。真实采集检查使用本进程创建的回环监听端口，不依赖外部目标。

Release 应用中实际检查了中文连接表、监听端口表、可见范围说明、工具菜单切换和正常刷新。UI 取消按钮、强制慢查询期间的快速切换/离开，以及各类失败的界面状态尚未完成可控的交互验收；这些路径目前有核心结果夹具、运行时取消测试和代码审阅。不能把它们写成已通过的 UI 测试。构建仍有既存的 CommandLineTools framework 搜索目录告警，但编译、链接和上述检查均完成。

T01 还需逐项迁移其他命令采集入口。T03 的批量扫描任务与进度事件、真实签名身份下的权限矩阵、其他系统版本以及正式公证均不属于本次完成范围。

## English

This batch was implemented and checked locally. No branch was pushed, no pull request was created or updated, and no GitHub issue was changed.

Connections and Listeners previously consumed array-returning APIs. A nonzero `lsof` exit became an empty array, making collection failure look like a successful query with no rows. The new result APIs retain command evidence, and both pages now consume them. Existing array callers retain compatibility.

`collect(scope:includeUDP:timeout:cancellation:)` is asynchronous; `collectSync` is the blocking boundary. A result contains selected entries, the number of valid source entries before filtering, stable issue codes, the rejected-record count and the original `CommandResult`. The default budget is 10 seconds with a retained limit of 1 MiB per stream, using the existing bounded runtime. Task cancellation reaches that runtime.

`loaded` and `empty` describe a successful query within the account's visible scope. `partial` preserves valid source data with collection or classification issues, including when filtering leaves no matching rows. `unavailable` means no usable rows and at least one issue. The issue vocabulary distinguishes missing executable, launch permission, busy runtime, other launch failure, command failure, timeout, cancellation, truncation, incomplete cleanup, unrecognized output, unclassified TCP state and command messages. stderr is evidence, not a permission classifier.

Exit status 1 is accepted as no visible matches only when both streams and observed byte counts are zero, with no timeout, cancellation, launch error, truncation, cleanup problem or termination signal. A discarded prefix or whitespace output does not qualify.

Queries use the fixed system executable and argument list shown above. The parser consumes NUL-terminated fields inside LF-terminated process and file sets. It requires complete records, preserves IPv6 endpoints, accepts unknown future fields and repeated members of the TCP-information family, and rejects duplicate required fields or duplicate states. An incomplete final set cannot become a valid socket row. Ambiguous process boundaries clear identity so later files cannot inherit the preceding PID. Row identifiers are stable for identical records.

UDP does not require TCP state. TCP with missing or future state remains visible in the `all` result. The connections and listeners filters exclude such unclassifiable rows and report `unclassifiedTCPState`, keeping the result partial. The legacy array APIs and default-column `parse(_:)` remain available; new field-mode queries never silently fall back to column parsing. ARP, WiFi and dashboard result-state adoption remain follow-up work.

Both pages show loading, cancellation, explicit empty/error states and valid partial rows. A request identity plus the selected tool guards every completion. Replacing a refresh or leaving the view cancels the old task. Command details expose the exit status, rejected-record count and bounded stderr. New copy is available in English and Simplified Chinese.

The visibility note is always present. Apple’s Darwin implementation can silently skip processes for `EPERM` or `ESRCH`; a clean command exit therefore does not establish unrestricted system visibility. Neither an empty result nor a generic timeout is treated as Local Network privacy denial.

Local checks used arm64, macOS 27.2.1 (26B131), and Swift 6.4.2, preserving Swift 5 language mode and the macOS 14 minimum. The focused inventory checks, complete NMTest suite and NMCheck passed. The Debug products and arm64 Release app with its bundled MCP built successfully; deep/strict signature verification and plist lint passed. The bundled MCP integration suite also passed with the strict cooperative executor, using loopback targets and temporary support directories. Deterministic records exercise failure and partial-result semantics, framing, state classification and identity isolation. An owned loopback listener verifies the real system adapter.

The Release UI was inspected for its Chinese connections/listeners tables, visibility note, tool-menu switching and normal refresh. Controlled UI acceptance for the cancel button, switching/leaving during a deliberately slow query, and injected failure states remains outstanding; those paths currently have core fixtures, runtime cancellation checks and code review. Existing CommandLineTools framework-search warnings remain. Other inventory migrations, batch scanner jobs/progress, signed-app permission states, other OS versions and notarization are separate work.

## 依据 / References

- Installed `/usr/share/man/man8/lsof.8`, sections `OUTPUT FOR OTHER PROGRAMS`, `DIAGNOSTICS`, `SECURITY` and `-T`; local system lsof 4.91, libproc-based.
- [Apple lsof manual source](https://github.com/apple-oss-distributions/lsof/blob/main/lsof/lsof.8).
- [Apple Darwin process enumeration](https://github.com/apple-oss-distributions/lsof/blob/main/lsof/dialects/darwin/libproc/dproc.c), handling of `proc_pidinfo` errors.
- [Upstream lsof manual](https://github.com/lsof-org/lsof/blob/master/docs/manpage.md).

公开搜索本轮未返回可用正文；命令格式和退出语义另以本机手册、受控回环试验及 Apple/上游源码核对。未将本机真实连接表或原始测试日志写入仓库。

Public search did not return usable page content in this session. The command format and exit behavior were checked against the installed manual, controlled loopback observations and Apple/upstream source. Host connection tables and raw local test logs are omitted from the repository.
