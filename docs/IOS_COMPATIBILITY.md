# 国行一代手表与 iOS 的连接边界

核查日期：2026-11-09（北京时间）。当前版本为 **0.2.1（构建 3，报告 schema 3）**。本文区分安卓安装包的静态证据、Apple 平台接口事实，以及实体手表已观测和待验证的部分。

## 已知设备路径

Android 项目 [apple1day/mywatch](https://github.com/apple1day/mywatch/blob/3c6eaec129e24c0a4a696f27f493ae1753a1ca89/docs/APK_ANALYSIS.md) 记录了用户上传的欢太健康 `4.22.11_8c76bdd_250530` 的静态调用链：OnePlus 一代设备分支进入 BRClientDevice，以公开 Android API `createRfcommSocketToServiceRecord` 建立两个 secure RFCOMM 连接。

| 通道 | APK 中的服务 UUID |
| --- | --- |
| 主／命令 | `db764ac8-4b08-7f25-aafe-59d03c27bae3` |
| 数据 | `db764ac8-4b08-7f25-aafe-59d03c27bae4` |

安卓实现先连接主通道，约 1 秒后建立数据通道。以上是静态证据；还没有用户这块实体手表的 SDP 回包与完整业务握手结果。

这些 UUID 是 RFCOMM 服务标识。本 iOS App 不把它们传给 GATT 服务发现并据此声称移植成功。

## 2026-11-09 的实表新增证据

用户通过 0.1.0 提供了保持连接的 GATT 报告：7 个服务、14 个特征，其中存在 `00002760-08C2-11E1-9073-0E8AC72E1011` 下的 `…0011 / …0012 / …0013`，以及 `…1012` 下的 `…0014 / …0015`。这些实际服务使 BLE 协议路径值得验证；之前 Android 一代分支使用 RFCOMM 的结论，不能推出设备没有另一条 BLE 业务路径。

原厂 APK 的 `it0.e` 确认：手机向 `1011/0011` 写命令，订阅 `1011/0012`；文件服务存在时再订阅 `1012/0015`。本版没有使用缺少 APK 用法证据的 `0013`，也不把其他芯片示例 UUID 当作验证码确认通道。

0.2.0 实表报告确认两个通知通道均开启，共收到 **30 次通知、572 字节**，其中 **29 次早于查询提交**。提交查询后处理到一个通过帧长度及 CRC 检查的后续分片，接收器却因没有首片缓存报 `UNEXPECTED_FRAGMENT` 并停止；GATT 仍保持连接。已经有厂商通道数据，尚无完整能力回应或身份、绑定成功证据。旧报告合并两个通道计数，不能认定 29 次前置通知全属于同一命令。

0.2.1 修复这一接收缺陷：从订阅开始持续解析命令流，保留跨查询提交边界的字节和消息来源；孤片、序号间断及无关主动消息不再直接结束查询。查询前开始的完整能力消息仅作为主动能力诊断，不计为查询成功；目标能力仍须通过完整帧、CRC、路由和 protobuf 校验。详细代码及 APK 依据见 [绑定问题分析](BINDING_ANALYSIS.md)。

本版仍只发送同一条能力查询，不执行身份、密钥交换或业务绑定，也不保证清除手表六位码界面。收到后续分片并不能代替完整能力消息；接收修复的自动回归和实表验收状态见 [验证方法](VALIDATION.md)。

## Apple 公开接口的范围

### CoreBluetooth

[当前框架文档](https://developer.apple.com/documentation/corebluetooth) 同时描述 LE 和 BR/EDR 支持，所以“iOS 不支持任何经典蓝牙”并不准确。

Apple 的 [WWDC19：What’s New in Core Bluetooth](https://developer.apple.com/videos/play/wwdc2019/901/?time=556) 说明，这里的经典蓝牙支持使用 GATT over BR/EDR；App 仍通过 CBPeripheral、服务和特征访问设备。[官方 Classic 示例](https://developer.apple.com/documentation/corebluetooth/using-core-bluetooth-classic) 采用同样的模型。

**本项目的判断：** 在已核查的普通 iOS 公共 API 中，没有与 Android 按上述服务 UUID 打开任意 RFCOMM Socket 直接对应的能力。GATT over BR/EDR 也不能自动把手表现有的 RFCOMM 业务协议转换成 GATT。

### ExternalAccessory

[ExternalAccessory 官方文档](https://developer.apple.com/documentation/externalaccessory) 面向受支持的 MFi 配件；厂商决定哪些第三方 App 可以与其通信，并提供协议资料。[QA1657](https://developer.apple.com/library/archive/qa/qa1657/_index.html) 进一步解释了普通附近蓝牙配件为什么不会仅因存在就被 EA 列出。

本项目没有该国行一代支持相应 MFi/iAP 传输的证据，也没有厂商提供的协议标识。因此没有添加虚构的 `UISupportedExternalAccessoryProtocols`。

### AccessorySetupKit 与较新系统能力

[AccessorySetupKit 官方流程](https://developer.apple.com/documentation/accessorysetupkit/discovering-and-configuring-accessories) 提供发现、用户授权和配件设置；拿到配件后，实际通信仍由 CoreBluetooth 等框架完成。它不是任意 RFCOMM 通道接口。

当前 CoreBluetooth 文档提及的 iOS 26 Live Activity 后台能力也不改变 GATT 与 RFCOMM 的区别。本版只做前台诊断，未申请后台蓝牙模式。

## 当前实现及解释方式

1. BLE 扫描产生名称候选，不能据此认证型号或所有权。
2. CoreBluetooth 连接成功仅记为 GATT 连接成功。
3. 发现的服务、特征和标准值来自设备回包；用户主动点击协议检查后，额外订阅已核实的通知并发送一次已还原的传输能力查询。
4. 原厂绑定、手机消息通知同步和健康同步单独标记为未实现；这与已经启用的 GATT 特征通知不同。
5. RFCOMM 状态记为普通 iOS 公共 API 无直接对应实现，而非“已连接”或“手表不支持”。
6. 一次 ATT 写确认与有效协议能力回应分开记录；解析结束后到达的同连接 ATT 回调仍可补记确认或错误。两者都不升级为身份认证、系统持久配对或账号绑定成功。
7. 系统验证码不由应用自行重发。Apple 的[配对说明](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForSettingUpYourIOSDeviceAsAPeripheral/BestPracticesForSettingUpYourIOSDeviceAsAPeripheral.html)和 [DTS 解释](https://developer.apple.com/forums/thread/759435)区分了加密连接／bonding 与应用业务；当前 App 无法直接查询系统 bond 状态。

iOS 的 CBPeripheral identifier 不是蓝牙 MAC。本项目仅为内部选择保存 UUID，导出时使用每次会话独立的匿名标识；不会把它描述成“读取 MAC 后脱敏”。

schema 3 分开报告命令／文件通知及字节数，最多保留最近 32 条帧结构诊断，不保存原始 payload。单次协议会话累计最多接收 4096 次通知 / 256 KiB，命令解析器另有 64 KiB 累计输入预算，缓冲及重组也有独立上限。文件数据不作为命令应答解析，也不发送文件确认。

## 需要什么证据才能继续

- 0.2.1 能否在前置主动流之后继续接收，并得到 CRC 与结构校验通过的完整能力消息；报告须区分前置主动能力和查询提交后开始的消息。
- 独立 ATT 写入结果，以及完整能力中的实际版本与能力字段。协议没有事务 ID，提交后的消息也只能按时间归属，不能凭此宣称严格的请求对应关系。
- 依据对应版本，验证身份挑战、密钥协商及业务初始化的真实请求／回应。
- 明确哪一步使手表退出等待确认、进入正常使用；手机端静态代码不能证明固件界面的转换条件。

未发现广播、连接超时、没有标准电量、主动断开或单个孤立分片，均不足以单独证明设备彻底不兼容。完整的手机消息通知或健康同步仍取决于可用传输和设备端协议，不由界面移植、接收器修复或 SDK 升级自动完成。
