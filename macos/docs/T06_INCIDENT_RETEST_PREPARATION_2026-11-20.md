# T06 从维护事件准备复测

**日期：2026-11-20** · 本文记录事件发起复测切片，不代表 T06 整项验收完成。

## 实现范围

- 维护事件详情提供「准备复测」操作，并滚动到售后维护中的单服务复测表单。
- 表单载入事件关联的交接版本和设备地址。关联版本保持固定；工程师仍需显式选择交接测点和复测方法。选择基线行或证据不会覆盖事件设备地址，工程师可直接编辑目标。
- 准备过程通过现有请求初始化器生成新请求，清空旧授权、网络条件、基线证据选择和 DNS/TCP/HTTP 方法参数。填写授权及当前网络条件后，只有点击「开始复测」才调用既有单服务执行路径。
- 若旧复测仍在执行，准备另一事件时会取消旧任务；等待旧任务收尾期间不能开始新复测，旧任务返回的结果或错误不会覆盖新表单。
- 完成记录不会自动写入事件时间线。工程师先显式附加到项目，再通过事件时间线编辑器关联已保存结果。
- 新增独立用例 `NMTest --case incident-retest-preparation`，覆盖事件版本、地址预填、旧授权和隐藏方法参数清理，以及未关联事件不会继承旧版本或目标。

## 验证状态

- Release `TestRunner` 编译通过：`swift build --package-path macos -c release -Xswiftc -enable-testing --target TestRunner`。
- 最终界面改动的 Release GUI 编译通过：`swift build --package-path macos -c release -Xswiftc -enable-testing --product NETworkManagerMac`。
- `git diff --check` 及本切片新增文件的空白检查通过。
- 编译仍出现本机 Command Line Tools 搜索路径不存在的链接器警告，未阻止上述目标成功构建。
- 2026-11-23 单独运行 Release `NMTest --case incident-retest-preparation` 通过。
- 本轮未执行 GUI 操作或现场网络探测。

## 未完成验收

在隔离 Release arm64 中文 GUI 中验证事件选取、表单预填、授权重置、手动启动、结果显式附加及随后关联时间线。受控 LAN、VPN、真实现场及签名公证发布仍属于独立验收门禁。

## English summary

Maintenance incident details can prepare the existing single-service retest form with the incident's handoff revision and asset address. The engineer still selects a handoff row and method, enters current network conditions, and confirms fresh authorization. Preparing another incident cancels an active retest and prevents its late result or error from replacing the new form. A completed result is attached to the project and linked to the incident timeline in separate explicit actions. Release builds of `TestRunner` and `NETworkManagerMac`, plus whitespace checks, passed. The named Release check `NMTest --case incident-retest-preparation` passed on November 23. Chinese GUI acceptance remains pending.
