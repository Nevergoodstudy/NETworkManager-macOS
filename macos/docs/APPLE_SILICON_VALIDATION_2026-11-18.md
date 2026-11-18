# Apple Silicon 打包应用验收 / Apple Silicon packaged-app validation

日期 / Date: **2026-11-18**

## 中文

### 本机打包与运行

- 实机：Apple M4 Pro（Mac16,8），macOS 27.2.1。
- 使用 `./script/build_and_run.sh --verify` 构建 Release `.app` 并启动。脚本退出码为 0，进程持续运行。
- `NETworkManagerMac` 与内置 `NMCP` 均为 arm64；`verify-arm64.sh` 检查应用内所有 Mach-O 均仅含 arm64。
- `codesign --verify --deep --strict` 和 `plutil -lint` 均通过。本机包使用 ad-hoc 签名，不代表 Developer ID、公证或 Gatekeeper 下载流程已验收。

### 验收结果

- `python3 macos/Scripts/test-architecture.py`：arm64 可编译，Intel、Universal 请求被拒绝，现有输出未被覆盖。
- `swift run --package-path macos NMCheck`：通过。
- `swift run --package-path macos NMTest`：全部检查通过，覆盖 DNS 解析/传输、IPv4 与 IPv6 UDP/TCP、超时和取消等。
- Release `NMCP` 与打包 `.app` 内的 helper 均通过 `python3 macos/Scripts/test-mcp.py`；测试使用 loopback fixture 和临时支持目录。
- 实际 `.app` UI：Dashboard 显示本机网络接口、默认路由和活动套接字；Ping Monitor 对 `127.0.0.1` 的 10 次探测全部成功；DNS 系统解析将 `localhost` 解析为 `127.0.0.1`；Assets 工作区和添加设备表单可用；计算器、设置页面可打开。
- 验证过程中修复了资产工作区无效选择状态、缺失 SF Symbol 和 SwiftUI 同步发布告警；空工作区提示已补中文本地化。
- 新进程不操作界面启动 12 秒后，没有负几何尺寸、SwiftUI 发布或缺失符号记录。AppKit 负尺寸告警曾在无障碍自动化切换页面期间出现；触发源尚未完全定位。该次 Ping/DNS/UI 操作均正常返回，进程没有退出。
- 启动日志还记录了 macOS `com.apple.linkd.autoShortcut` 服务连接失败的 AppIntents 错误；应用仍正常启动和运行。该系统服务错误不等同于架构验证失败，但应与应用自身日志问题区分。

### 范围

这是一次 Apple M4 Pro / macOS 27.2.1 的实机打包应用验收，不证明每一代 M 系列设备或最低支持的 macOS 14 已逐台验证，也不覆盖所有网络设备和远端服务。架构策略及打包流程此前已在 GitHub Actions 的 `macos-15` 与 `macos-26` Apple Silicon runner 上通过；该 CI 结果和本机 UI 验收覆盖不同范围。

## English

### Local package and runtime

- Hardware: Apple M4 Pro (Mac16,8), macOS 27.2.1.
- `./script/build_and_run.sh --verify` built the Release `.app` and launched it successfully; the script exited with status 0 and the process remained running.
- `NETworkManagerMac` and the bundled `NMCP` are arm64. `verify-arm64.sh` checks every Mach-O in the app bundle and requires arm64 only.
- `codesign --verify --deep --strict` and `plutil -lint` passed. The local app uses an ad-hoc signature; this does not validate Developer ID signing, notarization, or the downloaded-app Gatekeeper flow.

### Results

- `python3 macos/Scripts/test-architecture.py`: arm64 compiles; Intel and Universal requests are rejected without replacing existing output.
- `swift run --package-path macos NMCheck`: passed.
- `swift run --package-path macos NMTest`: all checks passed, including DNS parsing/transport, IPv4 and IPv6 UDP/TCP, timeout, and cancellation.
- Both the Release `NMCP` executable and the helper inside the packaged `.app` passed `python3 macos/Scripts/test-mcp.py`, using loopback fixtures and temporary support directories.
- Live packaged-app UI checks: Dashboard displayed local interfaces, the default route, and active sockets; all 10 Ping Monitor probes to `127.0.0.1` succeeded; system DNS resolved `localhost` to `127.0.0.1`; the Assets workspace picker and Add Device form worked; calculator and Settings views opened.
- Validation fixes cover the invalid Assets workspace selection, missing SF Symbols, and SwiftUI publishing warnings; the empty-workspace message now has a Chinese translation.
- A fresh process launch with no UI interaction for 12 seconds produced no negative-geometry, SwiftUI publishing, or missing-symbol records. AppKit negative-geometry records appeared during accessibility-driven page navigation; their trigger has not been fully isolated. The Ping, DNS, and UI actions returned normally and the process stayed alive.
- Startup logs also contain an AppIntents connection error for the macOS `com.apple.linkd.autoShortcut` service. The app still launches and runs; this OS service error is distinguished from an architecture verification failure.

### Scope

This is a packaged-app check on one Apple M4 Pro running macOS 27.2.1. It does not establish per-model testing across every M-series device or on the minimum supported macOS 14, and it does not cover every network device or remote service. Architecture policy and packaging checks also passed earlier on the `macos-15` and `macos-26` Apple Silicon GitHub Actions runners; CI and local UI checks cover different scopes.
