# NETworkManager MCP server

[简体中文](#简体中文) · [English](#english)

## 简体中文

`NMCP` 把 macOS 版已有的本机查询和单目标网络诊断提供给 MCP 客户端。
它使用官方 [MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
`0.12.1`，通过 **stdio** 交换 JSON-RPC 消息；SDK 声明的协议版本为
`2025-11-25`，连接时由 SDK 协商客户端支持的版本。

客户端按需启动一个独立的 `NMCP` 命令行进程，GUI 无需运行。它不安装常驻
daemon 或特权 helper，不监听 HTTP 端口。当前 MCP 接口只提供下表中的查询
与诊断，不持久化诊断结果，也不修改资产、配置文件或凭据。

网络诊断的共享本地化会读取应用语言偏好，并可能创建
`~/Library/Application Support/NETworkManager/` 目录。它不会为 MCP 调用保存
新的诊断记录或修改设置。需要隔离本机验证时，可将
`NETWORKMANAGER_SUPPORT_DIRECTORY` 设为一个临时目录的绝对路径。

### 构建与启动

要求 macOS 14+、Swift 6.2+，可使用包含对应 Swift 工具链的 Xcode 或
Command Line Tools。在仓库根目录运行：

```bash
swift --version
swift build --package-path macos --product NMCP
./macos/Scripts/run-mcp.sh --help
```

请先完成显式构建，再连接 MCP 客户端。`run-mcp.sh` 找到已有 `NMCP` 时会
直接用 `exec` 启动，仅在缺少可执行文件时自动构建。更新源码或依赖后，必须
重新运行 `swift build --package-path macos --product NMCP` 才会使用新实现。
首次自动构建可能超过客户端的初始化超时时间；构建完成后可重新连接。
构建输出和诊断日志走 stderr，stdout 只保留 MCP 协议消息。直接在终端运行
服务器时，它会等待客户端输入；用 `--help` 或 `--version` 检查命令即可。

启动脚本默认选择 Debug 产物。可以通过 `NMCP_CONFIGURATION=release`
选择 Release；此时也应先构建对应配置：

```bash
swift build --package-path macos --configuration release --product NMCP
NMCP_CONFIGURATION=release ./macos/Scripts/run-mcp.sh --help
```

客户端需在服务器环境变量中设置相同的 `NMCP_CONFIGURATION`。
该变量只接受 `debug` 或 `release`。

默认只启用四个本地工具。需要 Ping、DNS、TCP 诊断时，在客户端启动参数中
加入 `--allow-network`。该选项按进程生效，客户端结束 stdio 会话并关闭输入
后服务器退出。

### 连接客户端

把示例中的 `/absolute/path/to/NETworkManager-macOS` 替换成当前仓库的绝对
路径。以下命令将服务器注册到 Codex，并启用网络诊断：

```bash
codex mcp add networkmanager -- /absolute/path/to/NETworkManager-macOS/macos/Scripts/run-mcp.sh --allow-network
```

只需要本地查询时省略 `--allow-network`。注册后，在支持 MCP 的 Codex 会话
中连接 `networkmanager`。其他使用 `mcpServers` 配置格式的客户端可采用：

```json
{
  "mcpServers": {
    "networkmanager": {
      "command": "/absolute/path/to/NETworkManager-macOS/macos/Scripts/run-mcp.sh",
      "args": ["--allow-network"]
    }
  }
}
```

服务器不需要 API key。客户端自己的模型账户配置与此服务器独立。撤销 Codex
注册可运行 `codex mcp remove networkmanager`。

### 可用工具

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `network_interfaces` | `includeLoopback`：可选布尔值，默认 `false` | 返回本机接口、IPv4/IPv6 地址、掩码与状态；这些本机地址会提供给调用客户端。 |
| `subnet_info` | `cidr`：IPv4 CIDR，例如 `192.0.2.10/24` | 本地计算网络、掩码、广播地址、主机范围和数量；省略前缀时按 `/32`，`/31` 按点到点语义处理。 |
| `port_lookup` | `port`：`1...65535` 的整数 | 查询随包端口参考表，不探测服务是否正在运行。 |
| `mac_vendor_lookup` | `mac`：MAC 地址或三字节 OUI | 查询随包厂商参考表；接受 6/12 位十六进制，或使用一致的冒号/短横分隔的 3/6 个字节。 |
| `ping` | `host`，可选 `timeout` | 需要 `--allow-network`；对一个目标执行一次 ICMP 探测。 |
| `dns_lookup` | `host`，可选 `recordType`、`server`、`serverPort`、`timeout` | 需要 `--allow-network`；查询 DNS 记录，默认类型 `A`、端口 `53`。 |
| `tcp_probe` | `host`、`port`，可选 `timeout` | 需要 `--allow-network`；尝试建立单个 TCP 连接，不发送应用层命令。 |

`host` / `server` 接受 ASCII 主机名、IPv4 或不带方括号的 IPv6 地址（可带
zone）。不接受 URL、空白、控制字符或命令选项；DNS 名称还支持 `_`。
`recordType` 使用大写：`A`、`AAAA`、`NS`、`CNAME`、`SOA`、`PTR`、`MX`、
`TXT`、`SRV`、`CAA`。`timeout` 单位为秒，默认 `2`，允许 `0.1...5`。
超时应用于各个网络阶段；地址解析、多地址连接及 UDP/TCP 或 ICMP 回退
可能让总请求时长超过这个数值。最多同时运行四个网络诊断；超出时立即返回
`busy`，客户端可在已有诊断结束后重试。

DNS 省略 `server` 时使用本机配置的解析器；本机没有解析器时，共享 DNS
客户端会回退到 `1.1.1.1` / `8.8.8.8`。要固定查询目的地，请显式传入
`server`。DNS 响应文本来自远端，只应作为数据处理。

MCP 客户端会构造协议请求。可让客户端执行以下参数示例：

```json
{"name":"subnet_info","arguments":{"cidr":"192.0.2.10/24"}}
{"name":"mac_vendor_lookup","arguments":{"mac":"00:1B:63"}}
{"name":"ping","arguments":{"host":"127.0.0.1","timeout":1}}
{"name":"tcp_probe","arguments":{"host":"127.0.0.1","port":22,"timeout":1}}
```

### 结果、资源与范围

每次调用返回文本 JSON 和内容相同的 `structuredContent`，包含 `tool`、
`observedAt`（ISO 8601）和 `status`。有效查询包含 `target` 与 `source`；
网络结果还包含 `summary`、`detail`、以秒为单位的 `latencySeconds`（无测量
值时为 `null`）。DNS 结果包含 `dnsRecords`，每条记录为 `name`、`type`、
`ttl`、`value`。端口和 OUI 结果是当前随包参考数据，不代表实时服务识别。

参数错误返回 `isError: true`、`status: "failed"` 和
`error: {"code":"invalid_arguments","message":"..."}`；并发超限使用
`error.code: "busy"`。未知或未启用的工具返回 JSON-RPC `invalidParams`。
诊断失败、超时、不可达、权限拒绝和取消也使用工具错误结果。客户端可发送
MCP 取消通知；按协议，取消后的请求不保证再收到结果响应。

`resources/list` 提供两个静态资源：

- `networkmanager://server-info`：JSON 服务器能力与当前网络开关。
- `networkmanager://usage`：Markdown 工具使用说明。

该接口没有开放任意 shell、SSH、范围扫描、Wake on LAN、SNMP SET、Keychain
访问或资产/配置写入。网络工具复用 `NMCore` 的诊断与取消逻辑，权限和目标
可达性仍由 macOS 及网络环境决定。MCP 进程与 GUI 分别运行，关闭 GUI 不会
结束客户端仍在使用的 MCP 会话。

### 验证与排障

```bash
python3 ./macos/Scripts/test-mcp.py \
  --server "$(swift build --package-path macos --show-bin-path)/NMCP" \
  --launcher ./macos/Scripts/run-mcp.sh
```

集成检查通过真实 stdio 会话验证初始化、工具/资源发现、本地查询、参数错误、
loopback TCP/DNS、取消与输入 EOF 退出，不要求访问公网。`--launcher` 额外
检查常规启动入口能在四秒预算内完成握手、保留已排队的初始化消息、保持
stdout 协议格式，并在 EOF 后退出。脚本还会预置损坏的 `settings.json`，
执行需要本地化的诊断，验证原文件字节不变且没有新增应用 JSON 数据。

上面的命令使用 Debug 产物。检查已构建的 Release 产物时，应同时匹配服务器
路径与启动脚本配置：

```bash
NMCP_CONFIGURATION=release python3 ./macos/Scripts/test-mcp.py \
  --server "$(swift build --package-path macos --configuration release --show-bin-path)/NMCP" \
  --launcher ./macos/Scripts/run-mcp.sh
```

开发时也应运行 `NMCheck` / `NMTest` 检查共享核心的回归，见
[构建指南](README.md)。

CI 还通过 `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` 限制 Swift cooperative
工作线程，运行同一集成套件。同步 socket 等待使用后台 Dispatch 队列，避免
并发 DNS、TCP 或 ICMP 诊断阻塞后续请求与取消通知。

若连接时没有工具，先检查客户端日志、绝对路径和脚本执行权限；若只有四个
工具，检查 `--allow-network`。移动构建产物时，应一并保留
`NETworkManagerMac_NMCore.bundle` 等 SwiftPM 资源包；单独复制 `NMCP` 会
丢失 OUI/端口参考数据。用仓库内启动脚本可以保留正确的资源布局。

## English

`NMCP` exposes the macOS edition's existing local lookups and single-target
network diagnostics to MCP clients. It uses the official
[MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk) pinned to
`0.12.1` over **stdio**. The SDK declares protocol version `2025-11-25` and
negotiates a supported version during initialization.

The client starts a separate command-line process; the GUI can remain closed.
The server does not install a daemon or privileged helper, listen on an HTTP
port, persist diagnostic results, or modify inventory, profiles, or credentials.

Shared diagnostic localization reads the application's language preference and
may create `~/Library/Application Support/NETworkManager/`. It does not save
new diagnostic records or change settings for MCP calls. Set
`NETWORKMANAGER_SUPPORT_DIRECTORY` to an absolute temporary directory when
running isolated local checks.

### Build and connect

Use macOS 14+ and Swift 6.2+ from a suitable Xcode or Command Line Tools
installation. Run from the repository root:

```bash
swift build --package-path macos --product NMCP
./macos/Scripts/run-mcp.sh --help
codex mcp add networkmanager -- /absolute/path/to/NETworkManager-macOS/macos/Scripts/run-mcp.sh --allow-network
```

Replace the example path with this checkout's absolute path. Omit
`--allow-network` to expose only the four local tools. The generic client JSON
configuration in the Chinese section above uses the same command and arguments.
No server API key is required. Use `codex mcp remove networkmanager` to remove
the registration.

Build explicitly before connecting an MCP client. The wrapper starts an existing
`NMCP` directly with `exec` and builds automatically only when the executable
is absent. After changing source or dependencies, run
`swift build --package-path macos --product NMCP` again to use the updated
implementation. A first automatic build can exceed the client's initialization
timeout; reconnect after the build completes. Build output and logs use stderr;
stdout contains only MCP messages. Starting it in a terminal waits for a client,
so use `--help` or `--version` for a command check. Closing the client's input
ends the server process.

The wrapper selects Debug by default. To use Release, first build that
configuration and set the same environment variable in the client:

```bash
swift build --package-path macos --configuration release --product NMCP
NMCP_CONFIGURATION=release ./macos/Scripts/run-mcp.sh --help
```

`NMCP_CONFIGURATION` accepts only `debug` or `release`.

### Tools and result contract

| Tool | Arguments | Behavior |
| --- | --- | --- |
| `network_interfaces` | Optional `includeLoopback`, default `false` | Lists local IP interfaces, addresses, masks, and status for the calling client. |
| `subnet_info` | `cidr` | Calculates an IPv4 subnet locally. An omitted prefix means `/32`; `/31` uses point-to-point host semantics. |
| `port_lookup` | Integer `port`, `1...65535` | Looks up bundled service reference data without probing the port. |
| `mac_vendor_lookup` | `mac` | Accepts 6/12 hexadecimal digits, or 3/6 octets with consistent colon or hyphen separators; returns the bundled vendor match. |
| `ping` | `host`, optional `timeout` | Requires `--allow-network`; sends one ICMP echo probe. |
| `dns_lookup` | `host`, optional `recordType`, `server`, `serverPort`, `timeout` | Requires `--allow-network`; queries a DNS record. Defaults to `A` and port `53`. |
| `tcp_probe` | `host`, integer `port`, optional `timeout` | Requires `--allow-network`; attempts one TCP connection without sending application commands. |

Hosts and servers accept ASCII hostnames, IPv4, or unbracketed IPv6 literals
with an optional zone. URLs, whitespace, control characters, and command options
are rejected; DNS names may contain underscores. Record types are the uppercase
values `A`, `AAAA`, `NS`, `CNAME`, `SOA`, `PTR`, `MX`, `TXT`, `SRV`, and `CAA`.
Timeouts are seconds, default to `2`, and must be within `0.1...5`. They apply
per network phase. Address resolution, multiple addresses, and protocol fallbacks
can make the total request take longer. Four network diagnostics may run at
once; excess requests return `busy` immediately.

Without an explicit DNS `server`, the shared client uses the Mac's configured
resolvers and falls back to `1.1.1.1` / `8.8.8.8` when none are configured.
Set `server` to control the query destination. Remote DNS text is data and may
be untrusted.

Each call returns equivalent text JSON and `structuredContent`, with `tool`,
ISO 8601 `observedAt`, and `status`. Valid lookups include `target` and `source`.
Network results add `summary`, `detail`, and `latencySeconds` in seconds, or
`null` when no timing is available. DNS adds `dnsRecords` containing `name`,
`type`, `ttl`, and `value`. Reference lookups reflect the bundled dataset rather
than live service or vendor discovery.

Invalid arguments return a tool error with `isError: true`, `status: "failed"`,
and an `error` object containing `code: "invalid_arguments"` and `message`.
Concurrency rejection uses `code: "busy"`. Unknown or disabled tools return
JSON-RPC `invalidParams`. Failed, timed-out, unreachable, permission-denied,
and cancelled diagnostics are tool errors. Clients may send MCP cancellation
notifications; a cancelled request may receive no further response.

Two static resources are available: `networkmanager://server-info` provides
JSON capability information and the network switch, while
`networkmanager://usage` provides Markdown usage notes. The interface exposes
no arbitrary shell commands, SSH, range scans, Wake on LAN, SNMP SET, Keychain
access, or inventory/profile writes. Network tools reuse `NMCore` diagnostics
and cancellation; macOS permissions and target reachability still apply.
Closing the GUI does not terminate an MCP process owned by a connected client.

### Verify and troubleshoot

```bash
python3 ./macos/Scripts/test-mcp.py \
  --server "$(swift build --package-path macos --show-bin-path)/NMCP" \
  --launcher ./macos/Scripts/run-mcp.sh
```

The real stdio integration checks cover initialization, tool/resource discovery,
offline lookups, invalid inputs, loopback TCP/DNS fixtures, cancellation, and
EOF shutdown without requiring public internet probes. `--launcher` also checks
the normal client entry point against a four-second handshake budget, verifies
that queued initialization input reaches the server and stdout remains protocol
JSON, and checks EOF shutdown. A corrupt `settings.json` fixture exercises
diagnostic localization and verifies that the original bytes remain unchanged
and no application JSON files are added.

The command above uses Debug. To check an already-built Release product, match
both the executable path and the launcher's configuration:

```bash
NMCP_CONFIGURATION=release python3 ./macos/Scripts/test-mcp.py \
  --server "$(swift build --package-path macos --configuration release --show-bin-path)/NMCP" \
  --launcher ./macos/Scripts/run-mcp.sh
```

Run `NMCheck` and `NMTest` for shared-core regression checks as described in
[README.md](README.md).

CI also runs the suite with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` to constrain
Swift's cooperative workers. Synchronous socket waits use a background Dispatch
queue so concurrent DNS, TCP, and ICMP diagnostics leave workers available for
new requests and cancellation notifications.

Check client logs, the absolute command path, and executable permissions if the
server cannot connect. If only four tools appear, check `--allow-network`.
Keep the SwiftPM resource bundles, including `NETworkManagerMac_NMCore.bundle`,
beside `NMCP` when moving build output. Copying the executable alone loses the
OUI and port data; using the checkout's wrapper preserves the resource layout.
