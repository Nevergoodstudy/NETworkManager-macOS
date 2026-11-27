# 现场项目 P0 验收记录 / Field P0 acceptance record

**日期：2026-11-19** · 目标平台为 Apple Silicon arm64、macOS 14+

[现场工程计划](FIELD_ENGINEERING_PLAN.md) · [MacBook 验收矩阵](MACBOOK_BENCHMARK_2026-11-18.md) · [索引](README.md)

## 结论

P0 的离线中文交接和单服务 DNS/TCP 复测已有工作区实现；离线流程、回环 TCP、回环 DNS 成功和中文超时已获得部分中文 Release GUI 观察，专项自动检查通过。**两项 P0 都未整项验收完成。** 运行中离开视图已有取消终态证据；点击取消按钮/Escape 路径仍未验收。真实局域网、VPN 分流、Local Network 权限与正式发布门禁仍未通过。已合并基线覆盖 T01–T04（4/16）；工作区另有 T05 稳定资产身份和 T06 多事件时间线的部分实现，**0/16 整项完成验收**。本轮功能与定向检查见 [T05/T06 记录](T05_T06_LOCAL_SLICES_2026-11-19.md)。

## 环境与自动检查

- 主机：Apple M4 Pro，macOS 27.2.1，`arm64`。
- 应用：隔离输出目录中的 Release arm64 `.app` 和 helper；签名为 ad-hoc，无 Team ID。启动与进程验证通过。已有打包生命周期记录还覆盖挂载、复制安装、替换、重复启动和卸载；这些检查不代表公证或 Gatekeeper 验收。
- 专项命令：`swift run --package-path macos -c release -Xswiftc -enable-testing NMTest --field-project-only`，通过，输出 `NMTest: field project checks passed`。
- 专项检查覆盖 v1 读取、字段与证据校验、结构化判据变化后失效、交接快照冻结、报告字段选择、敏感值过滤、授权/窗口验证、复测状态映射、TCP 对端、结果附加与项目往返持久化、基线引用校验。测试通过不等于每种结果都已在 GUI 或真实网络中触发。
- `git diff --check` 在本记录补充前通过；文档更新后再次运行。

## 中文 GUI 直接观察

- 用隔离文档查看既有 schema 1 项目。客户、站点、范围和原手工记录可保存重开；文件仍保持旧 schema，没有据此宣称已迁移到结构化版本。
- 打开损坏文件及超过 512 KB 的合成文件时，中文界面显示具体原因。系统原生 alert 外层文案仍可能是英文。
- 结构化合成项目有 3 条需求、2 个测点和 2 个已保存交接版本，每版 4 行。检查售后版本选择、旧判据快照未被新草稿覆盖，以及默认和逐字段报告预览/落盘内容一致。
- 双版本项目保存并重开后有 2 条授权回环 TCP 记录，一条中文、一条英文历史记录。两条均显示回环对端 `127.0.0.1`、IPv4、不可直接比较状态、授权引用/人员和结果摘要。
- 默认报告为 313 字节；搜索客户标记、`192.0.2.44`、凭据标记、SSID/BSSID 后均无匹配。该地址只作为旧合成验收快照存在；本轮没有对它发包。报告 SHA-256：`0f6543ba19b1bc5670373d804c52264d00b205cffcdae82ad90850e35743ff60`。
- 随后使用回环 DNS fixture `127.0.0.1:49554`，在中文 GUI 中分别观察成功（A=`127.0.0.1`、NOERROR）及超时（“DNS 服务器未在规定时间内响应。”），并显式附加保存。成功记录 `CAB54323-F3B9-4D9C-8ED6-57C17E60D7E7`；超时记录 `E0A62CC9-B0E9-43D8-BC07-9D7BC7566FA6`。fixture 已退出，输出 `fixture closed`，后续检查未见监听残留。此 DNS 文档没有完成关闭重开的 GUI 验收。
- DNS 运行中离开视图已有 GUI 操作和 SQLite 终态证据：run `260A1276-233F-4F19-BD5A-3C1A464555EA`，目标 `nm-timeout-20261119.test`，状态 `cancelled`，摘要“诊断已取消”，约 0.208 秒。点击取消按钮/Escape 路径尚未验收。
- 后续开发已转入 T05/T06，未继续重复 DNS 深测。新隔离 Release 包中文 GUI 已新建维护事件、添加报障条目并保存关闭重开；保留标题、负责人、工单号、版本关联与时间线文字。该新副本的 GUI 保存重开只证明事件路径；完整细节见 [本轮切片记录](T05_T06_LOCAL_SLICES_2026-11-19.md)。

## 合成项目文件

样例位于隔离临时目录 `/private/tmp/nm-field-retest.TPYVtm/fixtures-zh-20261119`，不含客户数据：

| 文件 | 用途 | 大小 | SHA-256 |
|---|---|---:|---|
| `acceptance-legacy-v1.nmfieldproject` | schema 1 兼容项目 | 337 B | `609e3ef74b124e54ec333ade08105be241b222104f0c057e9dc8d4dc842ba957` |
| `acceptance-two-revisions-v2.nmfieldproject` | schema 3 项目，结构化验收 v2，2 个交接版本和 2 条回环 TCP 记录 | 17,722 B | `0fda1514691d551b9c192933bbb3d20bb6fe8ea5b4156fd9aaa2d2e77e1a138b` |
| `acceptance-dns-clean-20261119.nmfieldproject` | schema 3，2 个交接版本、2 条 TCP 及 DNS 成功/超时记录，未做该文档的关闭重开 GUI 验收 | 21,191 B | `6149c441ad5536ed1d87338227df4f06adcf3368b3fbf50f45f5c7b84f7b8b07` |
| `NETworkManager-acceptance-report.txt` | 默认隐私精简报告 | 313 B | `0f6543ba19b1bc5670373d804c52264d00b205cffcdae82ad90850e35743ff60` |
| `selected-criterion-report.txt` | 显式选择判据字段的报告 | 382 B | `eb00a042c4b0468e3341abe22738f1c78824de5e9be071945c581545c54786db` |
| `corrupt-fixture.nmfieldproject` | 损坏文件中文提示 | 26 B | `6f48e1ac4c9f28dc694e3ea6c1b3c1cf6011a72bc2c53f6297531d0aa1e66832` |
| `oversized-fixture.nmfieldproject` | 512 KB 限制中文提示 | 524,289 B | `64a15cef6a19b6a3483709e322b10f1659486890e90d3540adfb904f3e6fcd08` |

临时目录清理后，这些本机路径将不再可用；哈希用于辨认本次样例，并非项目发布资产。

## 尚未验收

- 在独立验收工作中补充点击取消按钮/Escape 路径、DNS 文档关闭重开，以及取消结果不被误附加。已观察的回环成功、中文超时和离开视图取消不重复作为后续开发的前置步骤。
- 验证 TCP 拒绝、超时、权限受阻和切网后的不可比提示，并逐项比对界面、保存记录、默认报告和选字段报告。
- 在授权的受控 LAN 与 split DNS VPN 上复测系统 DNS、指定 DNS、独立已知 IP TCP 对照、拒绝后恢复、Wi-Fi/USB/VPN 切换以及 IPv4/IPv6；每个用例保留应用版本、系统、接口和实际对端。
- 已配置 DNS 服务器的访问存在 Apple 文档列明的 Local Network 隐私例外；系统 resolver 解析非本地名字无需该权限，`.local`/`.local.arpa` 属本地名字，不能泛称所有 DNS 查询都豁免。回环 fixture 不能证明 LAN 权限行为。权限用非 DNS 局域网 TCP 对端及 Apple 签发身份签名的 App 验证；ad-hoc 包和 Terminal 启动的 CLI 都不足以证明正式 App 权限行为。参见 [Apple TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)。
- 由第二名工程师只看分享版复核所选结论、观测条件、未结事项和跟进责任人；检查键盘完整路径及最低支持 macOS 14。
- Developer ID 与 Hardened Runtime 签名、公证和票据装订、下载后 Finder/Gatekeeper 首次打开、升级路径；以及 TLS 证书失败和 HTTP 非成功状态的后续独立阶段。
- T05 已有稳定资产身份及刷新保护，T06 已有项目内多事件时间线和本地工单号引用；两项定向 Release 检查通过。完整接口双栈/路由域、跨文件 Case/Observation 检索、巡检模板、工单接口和真实 NetBox/Zabbix 试点仍待开发或验收；不把当前切片标为整项完成。

## References

- [Apple TN3179: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy)
- [Apple TN3151: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api)
- [专项自动检查源码](../Sources/TestRunner/FieldProjectChecks.swift) · [验收检查](../Sources/TestRunner/FieldAcceptanceChecks.swift) · [复测检查](../Sources/TestRunner/FieldRetestChecks.swift)
