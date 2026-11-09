# 国行一代手表与 iOS 的连接边界

核查日期：2026-11-09（北京时间）。当前版本为 **0.4.1（构建 6，报告 schema 6）**。本文区分安卓安装包的静态证据、Apple 平台接口事实，以及实体手表已观测和待验证的部分。

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

0.2.0 实表报告确认两个通知通道均开启，共收到 **30 次通知、572 字节**，其中 **29 次早于查询提交**。提交查询后处理到一个通过帧长度及 CRC 检查的后续分片，接收器却因没有首片缓存报 `UNEXPECTED_FRAGMENT` 并停止；GATT 仍保持连接。当时已经有厂商通道数据，该报告尚无完整能力回应或身份、绑定成功证据。旧报告合并两个通道计数，不能认定 29 次前置通知全属于同一命令。

0.2.1 修复这一接收缺陷：从订阅开始持续解析命令流，保留跨查询提交边界的字节和消息来源；孤片、序号间断及无关主动消息不再直接结束查询。查询前开始的完整能力消息仅作为主动能力诊断，不计为查询成功；目标能力仍须通过完整帧、CRC、路由和 protobuf 校验。详细代码及 APK 依据见 [绑定问题分析](BINDING_ANALYSIS.md)。

0.3.0 根据真实完整能力继续执行协议版本 3–5 的身份挑战及必要的 RSA/AES 协商，当时在身份之后停止，没有发送首次设置业务。用户早前照片显示 App 已取得协议能力、版本为 5、传输身份已通过，而手表仍在手动配对画面。照片没有对应的完整 JSON，无法据此核实实际加密能力、逐命令结果或账号状态。

0.4.0 保留认证成功后的当前业务会话，用户点击“继续首次设置”后发送 `11/7` 开始请求；全部 ATT 分片确认后发送空 `11/11`，观察 `11/11` 或 `11/12` 状态。业务按实际能力使用明文或 AES 封装，不能只凭协议版本推断模式。本版仍未实现账号登录、云绑定或完整首次设置，也不保证这一组命令就能使手表退出配对画面。新增自动回归和实表验收要求见 [验证方法](VALIDATION.md)。

最新 18:03 截图是在另一轮连接中：GATT 已连接、查询 `1/1` 个 ATT 分片已确认，但完整能力没有取得，身份和首次设置尚未开始。这次尚未走到账号业务。旧 UI 会在总通知数为 0 时隐藏收包行，截图未显示该行提示需要核对当轮接收情况，但不足以确定失败根因。后续 JSON 附件实际为 0.2.0 / build 2 / schema 2，生成时间为北京时间 14:11:32，不能用其中的旧分片错误及 30 次通知解释 18:03 的新故障。

0.4.1 依据 APK `ot0.a.M()` 及超时 Runnable，为原 `1/1` 查询增加首发后最多 3 次重试。每次实际提交至少 2 秒且上一条全部 ATT 确认后才重发；完整有效能力停止后续重试，当前已排队或提交的查询仍须确认。保持同一接收器、首次查询的来源边界及首次实际提交起 45 秒总窗口。原厂 Android 的约 2 秒重连间隔是另一条静态证据，本版没有据此增加 iOS 自动重连延迟。此调整补齐单次查询的鲁棒性缺口，不证明本次失败一定是首包丢失，也不证明重试足以使固件完成绑定。

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

当前 CoreBluetooth 文档提及的 iOS 26 Live Activity 后台能力也不改变 GATT 与 RFCOMM 的区别。本版的连接验证与实验性首次设置均在前台运行，未申请后台蓝牙模式。

## 当前实现及解释方式

1. BLE 扫描产生名称候选，不能据此认证型号或所有权。
2. CoreBluetooth 连接成功仅记为 GATT 连接成功。
3. 发现的服务、特征和标准值来自设备回包；用户主动点击连接与身份验证后，额外订阅已核实的通知并发送能力查询，按上述门禁有界重试，随后依据实际完整能力及写入结果启动已实现的身份分支。
4. 认证成功后，用户可在同一连接点击“继续首次设置”。`11/7` 和 `11/11` 的写确认分别记录，状态 `0`、`10...59` 表示仍待完成，`60` 仅记为手表报告首次设置已完成，其他有效数值记为未识别。账号绑定、手机消息通知同步和健康同步仍标为未实现；GATT 特征通知不是手机消息通知同步。
5. RFCOMM 状态记为普通 iOS 公共 API 无直接对应实现，而非“已连接”或“手表不支持”。
6. 一次 ATT 写确认与有效协议能力回应分开记录；解析结束后到达的同连接 ATT 回调仍可补记确认或错误。两者都不单独升级为身份认证、系统持久配对或账号绑定成功；当前身份成功必须另经挑战、所需会话证明及全部写入校验。没有命令通知、仅有文件通知、空命令通知和消息未完整解析分别说明；0 条通知也可见，不能据“没有完整能力”就直接判断没有任何蓝牙数据。
7. 系统验证码不由应用自行重发。Apple 的[配对说明](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/BestPracticesForSettingUpYourIOSDeviceAsAPeripheral/BestPracticesForSettingUpYourIOSDeviceAsAPeripheral.html)和 [DTS 解释](https://developer.apple.com/forums/thread/759435)区分了加密连接／bonding 与应用业务；当前 App 无法直接查询系统 bond 状态。
8. 开始设置之前的旧状态不能推进本轮；查询前开始的消息仅记为主动观测，不会在写入后重新归为查询应答。查询从首片实际提交起最多观察 45 秒，进度通知不延长时间。断连、后台、切换设备或观察结束后释放业务会话；重试须重新连接并验证身份。

iOS 的 CBPeripheral identifier 不是蓝牙 MAC。本项目仅为内部选择保存 UUID，导出时使用每次会话独立的匿名标识；不会把它描述成“读取 MAC 后脱敏”。

schema 6 保留身份阶段、逐命令 ATT 结果、分通道通知计数及 schema 5 的 `vendorProtocol.initialSetup / businessSessionState / businessEncrypted`、`commandWrites.serviceID / encrypted`。新增 `vendorProtocol.capabilityQuery`，分开记录查询已排队、实际提交和完整确认次数、当前轮次、上限与是否取得能力；`commandWrites.queryAttempt` 从 1 起关联各次发送。首次查询的原有 ATT 字段继续保留原义，不改成重试汇总。协议没有 transaction ID，轮次不能严格归属能力回包。

`capabilityTimeoutReason` 记录到期时的写入与接收分类，错误仍是 `PROTOCOL_RESPONSE / 1001`，不宣告未知根因。`commandNotificationActivation / fileNotificationActivation` 区分通知已经开启、已请求开启和已得到状态回调确认等情况；各自的 `NotificationCallbackCount` 是状态回调数，不是实际数据通知数。这些字段帮助检查重连后的订阅表现，没有改变订阅策略。

首次设置报告将查询前状态与本轮查询后的状态分开，最多保存 16 条数值观测；`accountBinding` 始终为 `NOT_IMPLEMENTED`。最多保留最近 32 条帧结构诊断，不保存原始 payload、密文或密钥。导出界面显示快照实际版本和生成时间及 UTC 偏移，文件名包含 `v0.4.1-b6-`、快照本地生成时间和随机短后缀，便于把报告与当次观察配对；缺失字段显示未知，不回填当前 App 值。

单次协议会话累计最多接收 4096 次通知 / 256 KiB，命令解析器另有 64 KiB 累计输入预算，缓冲及重组也有独立上限。逻辑命令最多 10 条，可容纳 4 次能力查询、4 条身份消息及 2 条设置消息；重试不放宽接收预算。加密业务必须在完整 CRC 校验和重组后用本连接会话解密，模式不符会停止业务验证。文件数据不作为命令应答解析，也不发送文件确认。

## 需要什么证据才能继续

- **0.4.1 / build 6 / schema 6** 的完整 JSON，并核对 `generatedAt` 和文件名时间确属刚才的连接。先看 `capabilityQuery`、每次 `queryAttempt` 的 ATT 结果、分通道通知数和字节数、解析诊断及失败原因，确定本轮是否已越过能力阶段。旧版附件不能用于验证本版修复。
- 若身份通过，补全早前照片缺少的实际能力、能力来源和逐命令 ATT 结果；尤其核对 `businessEncrypted`，不能从版本 5 推断是否加密。
- `11/7` 与 `11/11` 是否分别完整写入，状态是否来自本次查询提交后的完整消息。协议没有事务 ID，时间归属不能宣称严格的一问一答关系，查询前主动状态必须独立保留。
- `initialSetup` 的数值状态、来源、字段是否实际编码及失败／超时原因，确认卡点是写入、解密、状态观测还是更后的业务步骤。待完成状态不自动解释为账号登录失败。
- 点击“继续首次设置”前后的手表画面、确认动作及能否进入主界面。即使收到状态 60，也需分别验证账号和实际可用功能；手机端静态代码不能证明固件界面的转换条件。

未发现广播、连接超时、没有标准电量、主动断开、单个孤立分片或首次设置仍待完成，均不足以单独证明设备彻底不兼容。当前既不能保证完全离线激活，也没有证据认定手表已无法使用；需要依据这块固件的真实业务回复继续判断。完整的账号绑定、手机消息通知或健康同步仍取决于可用传输和设备端协议，不由界面移植、接收器修复或 SDK 升级自动完成。
