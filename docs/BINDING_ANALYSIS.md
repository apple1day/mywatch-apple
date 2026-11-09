# 一代国行 OnePlus Watch：连接、身份与绑定证据

更新：2026-11-09。本文记录 WatchLink **0.4.2（构建 7，报告 schema 7）** 的实现边界及后续协议工作的依据。分析来自用户提供的欢太健康 APK、经脱敏归纳的实机报告与照片，以及 Apple 官方文档；没有运行目标 APK 或其原生库。

**最新 0.4.1 完整报告显示 GATT 请求后约 1 秒收到 `CBErrorDomain / 14`，本轮未连接、未发现服务、未提交能力查询。该错误表示系统报告对端已移除配对信息，不能据此判断由谁或什么操作触发。0.4.2 增加这类连接错误的恢复指导、结构化诊断和未开始阶段的准确显示；用户仍须在系统设置中处理对应配对记录。此前能力查询重试、身份认证、首次设置开始与状态查询继续保留。账号登录、云绑定及完整首次设置仍未实现；本版没有把显示恢复步骤当作系统配对或实表连接已经恢复。**

## 0. 0.4.2 的实际实现与门禁

- GATT 连接／断开回调独立保存为 `observations.gattFailure`，包含 `stage / domain / code / occurredAt / errorIdentifier`。只有域与错误码均匹配时，才识别为 `PEER_REMOVED_PAIRING_INFORMATION` 并显示对应恢复步骤；不把其他域的数字 14 当成同一错误。
- 连接按钮附近显示本轮失败原因，并提供重新扫描入口。系统配对记录由用户在设置中处理；本版不自动清除配对信息。失败事实在本轮报告中保留，实际开始新的扫描／连接或切换目标才开始新的观测；查看恢复说明不代表恢复成功。
- `VendorCapabilityQuery` 管理同一连接中 `1/1` 的首发和最多 3 次重试。每次实际提交至少 2 秒且全部 ATT 分片确认后，尚未取得完整有效能力才允许重发。能力一旦有效就停止安排新重试；已排队或提交的当前查询仍须完成，首次主动能力也不跳过首发查询及确认。
- `OppoAuthentication` 是一次性身份状态机：真实完整能力 → `1/24` 随机值 → `1/25` 反码挑战 → 按能力位决定 `1/36` RSA / `1/37` AES 会话证明 → `1/37 state=1` 写确认。
- 查询必须实际获得 ATT 确认才开始身份流程。查询后的能力优先；查询前主动能力也可用于版本选择，但来源独立记录，不能追认为查询应答。先校验同一通知批次和历史观测中的能力一致性，再处理可能完成认证的回复；矛盾参数会停止流程。
- 重试不重置接收器、不重新标记首次查询的流偏移，也不延长从首次实际提交起算的 45 秒总窗口；只重发已经核实的原查询，不新增私有前置消息。每轮最多 10 条逻辑命令，容纳 4 次能力查询、4 条身份消息和 2 条设置消息。
- 每个阶段在首个 ATT 分片真正提交前记录命令流偏移；排队前或旧首片开始的消息不用于新阶段。原厂没有事务 ID，这一时间边界不宣称严格事务证明；身份挑战另与本次随机挑战匹配。
- 回复可早于 ATT 回调，但必须等该逻辑命令的全部分片成功写入后才推进。最后的 `state=1` 也必须写入成功；没有照抄 APK 在失败回调中仍标协商完成的行为。
- 保持完整 TL 帧不超过 `min(20, peer frame, peer MTU, actual ATT maximum)`；协商间隔以毫秒作用于分片及跨命令发送。超过 1000 ms 的间隔或无法在界限内编码的帧明确失败，不扩大到未知传输参数。
- 版本 1–2 明确停止，保留旧密钥路径未适配的原因。0.4.0 的业务发送限于 `11/7` 开始设置及 `11/11` 状态查询；不发送云绑定成功、同步完成、结束设置、文件、解绑、重置或固件命令。
- `OppoCrypto` 使用系统 AES、MD5 和 Security RSA 原语，身份 KDF 与封装按下文还原。随机挑战使用系统安全随机数。0.3.0 完成身份后释放全部协商材料；0.4.0 的 `takeBusinessSession()` 仅在认证完整成功后一次性移交当前连接所需的明文模式或 AES 上下文。身份挑战等临时材料释放，业务密钥不写入 Keychain、磁盘或报告；断连、后台、失败或观察结束时使业务上下文失效。
- 用户点击“继续首次设置”后，`OppoSetup` 才发送 `11/7` 的 `08 01 10 02`；收到整条命令的全部 ATT 确认后发送一次空 protobuf 的 `11/11`。查询写确认前的有效新状态有限缓存，写失败不采用；查询前开始的状态另存为 `preQueryObservation`。
- 业务封装严格遵循实际协商模式。加密分支先将完整 SID/CID/protobuf 用 AES 封装，再分片，每片带 `0x40`；收齐并检查 CRC 后才解密。已协商加密时不退回明文，跨片加密标志变化或模式不符不会被当作有效设置状态。
- `11/11`、`11/12` 的有效状态 `0`、`10...59` 保持待完成；仅 `60` 标记 `DEVICE_SETUP_FINISHED_REPORTED`。查询首片实际提交后固定观察 45 秒，不因状态通知延长。到期仍在进行则记 `DEVICE_SETUP_PENDING`，未知状态记 `DEVICE_STATE_UNRECOGNIZED`，没有本轮有效状态则明确超时；所有结果均保留 `accountBinding=NOT_IMPLEMENTED`。
- schema 4 的 `authentication` 与 `commandWrites`、schema 5 的 `initialSetup / businessSessionState / businessEncrypted`、schema 6 的 `capabilityQuery / queryAttempt` 保留；schema 7 新增 `observations.gattFailure`。只记录阶段、来源、数值状态、证明结果、ATT 分片计数及有界系统错误信息，不保存 nonce、挑战、密钥、验证密文、原始 protobuf 或 `NSError.userInfo`。
- 界面区分选择设备、GATT、能力、传输身份、首次设置与账号绑定。按钮按真实阶段和终态显示文案，灰色本身不是成功标志。命令／文件收包数在为 0 时也显示，能力失败按实际接收事实分类；导出显示版本及生成时间，文件名包含 `v0.4.2-b7-` 和时间，方便核对同一轮报告。

实现入口为 [`VendorCapabilityQuery`](../Sources/WatchLink/VendorCapabilityQuery.swift)、[`OppoAuthentication`](../Sources/WatchLink/OppoAuthentication.swift)、[`OppoBusinessSession`](../Sources/WatchLink/OppoBusinessSession.swift)、[`OppoProtocol`](../Sources/WatchLink/OppoProtocol.swift)、[`OppoSetup`](../Sources/WatchLink/OppoSetup.swift) 与 [`BluetoothMonitor`](../Sources/WatchLink/BluetoothMonitor.swift)。自动检查结果以本次提交的 CI 为准；测试向量来自独立重建和标准向量，不能冒称官方或手表抓包。

## 1. 实机已经证明什么

用户在 iPhone 的数字确认弹窗中点击了确认，随后手表仍停留在确认界面。0.1.0 导出的诊断报告显示：

- GATT 连接在诊断结束及导出时仍保持，标准设备信息读取完成。
- 共发现 **7 个服务、14 个特征**；界面合计 21 项并不代表 21 个服务。
- 报告中的 3 条事件没有记录 ATT 错误。
- 当时没有执行厂商通知订阅、能力协商、身份认证或绑定命令。因此没有厂商协议错误记录，也没有厂商协议成功证据。
- 实机确实暴露了 APK 中通用 BLE 传输使用的命令及文件服务。这使 BLE 业务入口值得验证，但服务存在不等于该固件接受完整绑定流程。

后续 **0.2.0 实机报告**提供了进一步证据：命令和文件通知均启用；收到 **30 次通知、572 字节**，其中 **29 次在提交查询之前**。提交查询后的首条被处理的命令通知含有通过长度、CRC 和已知 control 检查的后续分片，但接收器没有首片缓存，抛出 `UNEXPECTED_FRAGMENT` 并终止探针。GATT 仍然连接。

因此不能将 **0.2.0 这一轮**描述为“没有厂商通道数据”：已经收到有效外层帧的后续片，尚未获得完整能力消息。旧报告合并统计命令和文件通知，且没有逐帧元数据，**不能证明前 29 次通知全是这一命令的前导分片，也不能还原具体 FSN**。报告中的 `attWriteAcknowledged=false` 仅表示当时没有记录到 ATT 确认，不等于系统明确报告写入失败。

**此前身份通过的用户照片**进一步显示：App 的蓝牙通道已连接、协议能力已取得、传输身份已通过，协议版本显示为 5；手表仍停留在“手动配对／请选择该手表配对”画面。这是一次真实界面观测，说明曾推进到传输身份，不能因另一轮失败而将其抹去。但尚未取得与该照片对应的完整诊断 JSON，不能据此核实 `supportProtocol`、RSA/AES 分支、全部写入回调或消息来源，也没有账号登录失败、云服务关闭或手表完成首次设置的证据。0.4.0 的设置请求和状态观察尚待新一轮实表报告。

**此前 18:03 截图**显示另一轮验证：GATT 已连接，当前查询 `1/1` 个 ATT 分片已确认；能力仍在等待，传输身份及首次设置均未开始，错误为未取得可用于身份认证的完整能力。该截图只能确认卡在能力阶段，不能把“写入完成”解释为手表已处理请求，也不能判断是未发通知、只发了无关通知，还是完整消息没有解析出来。旧 UI 在总通知数为 0 时隐藏收包行，因此截图未显示该行值得核对，但不能替代当轮报告中的计数。

随后提供的附件实际上仍是 **0.2.0 / build 2 / schema 2**，`generatedAt=2026-11-09T06:11:32Z`，即北京时间 **14:11:32**。它对应前述旧分片错误，不能作为 18:03 这次更新后能力超时的收包证据，也不能用于判断 0.4.1 是否修复。下一轮必须同时核对版本、构建号与生成时间。

### 最新 18:46 的 GATT 连接失败

新附件确认为 **0.4.1 / build 6 / schema 6**，`generatedAt=2026-11-09T10:47:02Z`，即北京时间 **18:47:02**，与本轮截图时间对应。报告提供了此前截图没有的明确系统错误：

| 项目 | 本轮实际观测 |
| --- | --- |
| 请求连接 | 北京时间 18:46:11 |
| 系统失败回调 | 北京时间 18:46:12，`CBErrorDomain`，code `14` |
| GATT | `result=GATT_CONNECT_FAILED`；`gattConnectionObservedThisAttempt=false`，导出时也未连接 |
| 服务和标准信息 | 两者均为空，没有进入服务发现与标准读取成功阶段 |
| 厂商协议 | `status=NOT_ATTEMPTED`；查询排队、提交和确认均为 0；未请求命令／文件通知，没有协议命令写入 |

`CBError.Code.peerRemovedPairingInformation` 表示对端已移除配对信息。该定义是系统错误的含义；这份报告没有记录对端清理的原因，不能进一步断言用户恢复了出厂设置、某次 App 更新清除了密钥，或者云账号拒绝了登录。扫描时能收到广播不等于旧配对信息仍可用于建立连接。

代码对照 `e7c6b7`（0.4.0）与 `bc084eb`（0.4.1）确认，`connectSelected()`、创建 central、`manager.connect(...)`、`didConnect` 与 `didFailToConnect` 的连接路径没有修改。新增查询逻辑在 GATT、服务发现及通知订阅之后运行；本轮查询计数为 0，证明尚未执行到该逻辑。这里可排除“本轮已经发出了新重试查询再导致错误 14”的说法，不能反推出所有硬件状态变化的来源。

可立即由用户操作的恢复路径是：iPhone **设置 → 蓝牙 → 对应 OnePlus Watch 记录右侧 ⓘ → 忽略此设备**，让手表保持配对页面，再回 App 重新扫描、选中并连接。必须确认对应目标，不能批量清除其他设备的配对。若列表没有该记录或仍失败，保留新的报告继续定位。现有 CoreBluetooth 连接方式不能代替系统执行这一步；AccessorySetupKit 对其管理配件的移除属于另一套流程，不能据此认定本 App 能移除任意旧 CoreBluetooth 配对记录。

0.4.2 修复的是失败提示位置、错误解释、结构化报告以及“未开始却显示等待结果”的界面问题。本版保留手动重新连接，不通过自动循环重连、伪造配对成功或发送额外厂商命令处理此错误。能否恢复连接及继续身份／设置，仍以操作后的实表回调为准。

本文不保存设备名后缀、匿名设备标识、照片或完整原始报告。标准设备信息中的字符串也不能单独用于确认内部芯片或固件实现。

### 连接、配对和业务状态必须分开

| 层次 | 目前的证据 | 不能由此推出的结论 |
| --- | --- | --- |
| Core Bluetooth / GATT | 早前有 `didConnect`、服务发现及标准读取；18:46 这一轮未连接并报错 14 | 把某轮成功覆盖到另一轮，或由连接成功推出业务绑定完成 |
| 系统 SMP 配对及密钥保存 | 早前用户确认系统数字弹窗；18:46 系统报告对端已移除配对信息 | 本项目已独立验证 bonding 持久保存，或知道哪次操作清除了对端信息 |
| 厂商传输与身份 | 0.2.0 报告有有效后续分片；早前照片显示版本 5、身份已通过；18:03 的另一轮停在能力阶段 | 将不同轮次合并成一份结果，或仅凭照片确定实际加密分支、完整时序及账号状态 |
| 首次设置与账号绑定 | 身份通过照片中手表仍处于手动配对；0.4.0 新增开始请求及状态观察，18:03 这一轮尚未启动 | 已激活、账号已绑定，或反过来认定必须登录失败／已无法使用 |

Apple 将 `didConnect` 定义为与外设连接成功，`CBPeripheral.state` 表示连接状态。这些项目中已有的观察不能充当系统配对完成回执。系统配对、保存配对密钥和厂商应用协议分别处理不同问题；即使前一层成功，仍需验证后续层。相关官方链接见文末。

## 2. 已核实的 BLE 通道

以下方向根据 APK 的实际订阅和写入调用确定，而非根据常量中的 `READ` / `WRITE` 字样猜测。

| 用途 | 服务 UUID | 特征 UUID | 手机操作 |
| --- | --- | --- | --- |
| 命令发送 | `00002760-08C2-11E1-9073-0E8AC72E1011` | `00002760-08C2-11E1-9073-0E8AC72E0011` | 写入，手机 → 手表 |
| 命令回复 | `00002760-08C2-11E1-9073-0E8AC72E1011` | `00002760-08C2-11E1-9073-0E8AC72E0012` | 订阅通知，手表 → 手机 |
| 文件发送 | `00002760-08C2-11E1-9073-0E8AC72E1012` | `00002760-08C2-11E1-9073-0E8AC72E0014` | 写入，手机 → 手表 |
| 文件回复 | `00002760-08C2-11E1-9073-0E8AC72E1012` | `00002760-08C2-11E1-9073-0E8AC72E0015` | 订阅通知，手表 → 手机 |

来源：`ht0.f`；`it0.e.a.onConnected()` 先订阅 `0012`，若文件服务存在再订阅 `0015`；`it0.e.z()` 写命令，`it0.e.y()` 写文件；`it0.i.a()` 调用 GATT 写入。

实机还存在 `0013` 及其他服务，但上述 APK 路径没有提供 `0013` 的使用依据。不能把其他厂商示例中同 UUID 的 ACK 行为直接套到手表上。

Android 官方的一代设备分支选择 `connectionType=4`，经 `ht0.b.u()`、`jt0.d`、`jt0.b.Y()` 建立安全 RFCOMM 命令及数据连接。这个事实说明官方 Android 路由选择，**不能证明固件不存在 BLE 替代入口**；反过来，发现 BLE 特征也尚未证明替代入口能完成首次绑定。

## 3. 基础 TransportConsult 查询（0.2.1 的唯一请求）

请求由 APK 的 `ot0.a.M()`、`ConsultProto.TransportConsult` 和 `ps0.g.j()` 构造链重建，使用官方 BLE 默认值，与 0.2.0 相同。它是 `sid=1, cid=1` 的传输能力查询，不是绑定确认。

精确 **18 字节**：

```text
aa 0e 00 00 01 01 08 05 10 14 18 14 20 0a 28 03 2c 16
```

| Protobuf 字段号 | 原字段名 | 查询值 | 含义 |
| --- | --- | --- | --- |
| 1 | `protocolVersion` | 5 | 客户端协议版本 |
| 2 | `maxFrameSize` | 20 | 客户端初始帧大小 |
| 3 | `maxTransimissionUnit` | 20 | 客户端初始传输单元；保留原拼写 |
| 4 | `interval` | 10 | 官方发送间隔；`ps0.c.q()` 将其用于毫秒级等待 |
| 5 | `supportProtocol` | 3 | 协议能力位值 |

应答使用同一消息结构。官方分派以 `sid=1` 和 `cid & 0x7f == 1` 匹配，故 `cid=0x01` 与 `0x81` 都可能进入该分支；没有在这里发现请求计数器。当前实现将完整请求的原样回显单独判为歧义，避免把回环当作成功协商。

### 0.4.1 的查询重试依据与范围

原厂 `ot0.a`（`ClientConsultHelper`）的 `M()` 每次构造上述同一个 `TransportConsult`，先调用 `Q(1, nd0.b.SCORLL_DELAYED)`，再通过 `F(1, 1, ...)` 发送。该常量在 APK 的 `classes18.dex` 中为 **2000 ms**，`M()` 内实际调用也已核对为 2000。其超时 Runnable 仅在当前等待类型 `m == 1` 且重试计数 `l < 3` 时递增计数并再次调用 `M()`；因此是 **首发 + 最多 3 次重试**，并非无限重发。`D()` 接收能力后取消当前计时并转入能力选择的身份分支；`b()` 在清理时归零重试数。

之前 iOS 版本只发一次能力查询。0.4.1 采用相同已核实请求的重试次数和 2 秒等待，并增加本地完整 ATT 确认门禁：从每次首片实际提交时开始计时，2 秒先到而 ACK 未完整时继续等待，不并发重复写。完整有效能力停止新重试；如果当前查询已经排队或提交，仍等待这一条完整写确认才进入身份。首次查询前已收到有效主动能力时仍执行并确认首发查询，保留其主动来源。

这一调整补齐了可定位的鲁棒性缺口，**不能由此断言 18:03 的能力等待失败一定由首包丢失引起，也不保证重试可使本固件恢复响应**。本版仍从首次实际提交起最多等待 45 秒，后续重试不延长；保留同一连续解析器及首次归属边界，不能将前置半帧或旧首片重新归为新查询。原厂消息没有 transaction ID，`queryAttempt` 仅标明发送轮次及其 ATT 结果，不能严格对应某一能力回包。

schema 6 的 `vendorProtocol.capabilityQuery` 记录 `status`、`queuedAttempts`、`submittedAttempts`、`acknowledgedAttempts`、`currentAttempt`、`maximumAttempts=4`、`retryDelayMilliseconds=2000`、`hasCapabilities`。轮次从 1 开始；排队、实际首片提交和整条写入确认分别计数。逐命令 `commandWrites.queryAttempt` 关联该轮写入，旧 `requestSubmitted / querySubmittedAt / attWriteAcknowledged / attWriteCallbackObserved / attWriteCompletedAt / attWriteError` 字段继续只表示首次查询，不改成最后一次或所有重试的汇总。

查询状态依次区分 `NOT_STARTED`、`QUERY_QUEUED`、`WAITING_FOR_WRITE_ACK`、`WAITING_FOR_CAPABILITIES`、`READY_FOR_AUTHENTICATION`；失败和中断另记为 `FAILED`、`INTERRUPTED`。第 4 次查询确认后仍没有能力时，保持等待直至首次查询的 45 秒截止或后续有效能力，不沿用原厂约 8 秒的整轮超时。这里的“可进入身份”只表示能力及查询写入门禁满足，身份是否通过仍由独立认证结果决定。

能力总窗口到期时，`vendorProtocol.capabilityTimeoutReason` 按以下优先顺序分类，仍使用 `error.phase=PROTOCOL_RESPONSE`、`code=1001`。分类描述接收与写入状态，不把推测的重连、配对或固件问题写成根因。

| 超时分类 | 已观测条件 |
| --- | --- |
| `CAPABILITY_WRITE_INCOMPLETE` | 已排队查询数大于完整确认数 |
| `CAPABILITIES_OBSERVED_NOT_ADVANCED` | 已有完整能力观测，但协商未进入下一阶段 |
| `NO_NOTIFICATIONS` | 命令与文件均未收到数据通知 |
| `FILE_NOTIFICATIONS_ONLY` | 收到通知，但命令通道计数为 0 |
| `EMPTY_COMMAND_NOTIFICATIONS` | 命令通知存在，但累计命令字节数为 0 |
| `INCOMPLETE_COMMAND_MESSAGE` | 已有命令字节，解析器仍有未收齐内容 |
| `NO_VALID_CAPABILITIES` | 已有命令字节，没有可用完整能力，且没有待收齐内容 |

`commandNotificationActivation / fileNotificationActivation` 另区分通知原本已开启 `ALREADY_ENABLED`、本轮已请求开启 `ENABLE_REQUESTED`、已收到成功状态回调 `ENABLE_CONFIRMED` 等观测；`commandNotificationCallbackCount / fileNotificationCallbackCount` 是通知状态回调数，不能与数据通知数混淆。这些新增诊断没有改变通知订阅行为。

还核对到原厂 Android `GattConnection` 的关闭／连接路径：关闭时记录时间，重新 `connectGatt` 前可等待补足约 2 秒。它与上述 `TransportConsult` 重试是不同机制；当前缺少证明 iOS 这次失败由重连间隔引起的实测依据，**0.4.1 未据此增加 iOS 自动重连或固定延迟**。已查看的连接完成 → consult helper → `M()` 调用链没有发现必须插入的额外私有前置请求。`D()` 本轮只采用第一次能力的标志也不能证明手表固件一生、一次配对或一次连接只发送一次主动能力。

### 外层帧及 CRC

来源：`ps0.g.j()` 编码，`ps0.g.u()` 字节流及 CRC 检查，`ps0.g.n()` 分片重组，`dt0.a.a()` CRC。

```text
AA | bodyLength | control LE16 | [FSN UInt8] | payload | CRC16
```

- `bodyLength` 为一或两字节的 7 位 varint，包含 control、可选 FSN 和 payload，不包含帧头、长度字段和 CRC。
- control 低两位为 `0` 单帧、`1` 首片、`2` 中片、`3` 末片。分片包含序号，后续序号须递增，按 256 回绕。
- `0x40` 表示加密。`0x08` 的业务含义未确定；当前仅保留这一已见标志，不把它称作 ACK。
- 明文 payload 是 SID/CID/protobuf；身份成功后的加密业务 payload 是对这三部分整体封装的结果。`ps0.g.j()` 先加密再分片，`n()` 先重组再解密；不能分别加密每个 BLE 片段或明文保留 SID/CID。0.4.0 才启用此业务路径，默认解码配置仍不输出加密消息。
- CRC 多项式为 `0x1021`，初值 0，无反射，无最终异或，覆盖从 `AA` 到 payload 末尾。查询的 CRC 数值为 `0x162c`。
- APK 发送时使用小端尾部 `2c 16`；其接收路径接受与计算结果匹配的**小端或大端**尾部。0.2.1 解码器保留这一兼容性，并记录实际校验字节序。
- BLE 通知边界不等于协议帧边界：通知可能只含半帧，也可能含连续多帧。重组帧后还要处理协议分片。

0.2.1 对目标能力消息仍严格检查长度、CRC、分片、路由及 protobuf。字段 1–3 必须显式存在并为正值；当前识别版本 1–5。Proto3 可将字段 4、5 省略为默认 0，因此解析结果同时记录字段是否实际编码。0.2.1 的原始能力值只用于报告；0.3.0 在上述保守上限内使用实际参数；例如官方经典链路默认 MTU 为 990，不能仅因该数值大于某个 BLE 默认值就丢弃诊断事实。

**ATT 写入完成只证明该写入操作完成；有效能力应答只证明能力协议被响应。两者都不是身份或绑定成功。** 0.2.1 在能力查询之后停止；0.3.0 继续执行第 0、4 节身份流程，当时仍不发送 OOBE。0.4.0 在身份之后新增第 5 节的开始设置与状态查询，仍不发送账号云成功或同步完成消息。

### 0.2.0 的接收缺陷及 0.2.1 的修复

0.2.0 的 `BluetoothMonitor.receiveVendorData()` 在查询提交之前仅统计通知；`requestSubmitted` 为 false 时，命令数据也直接返回，没有送入分片接收器。查询提交后若收到主动消息的中片或末片，空缓存就会触发致命错误。上述实机表现与这一缺陷相符，但旧报告不足以证明丢失首片的具体通知顺序。

重新核对 APK 确认 **1=首片、2=中片、3=末片的解释正确**。实际差异在接收容错：`ps0.g.n()` 对孤立后续片或序号不连续只丢弃当前片；新首片替换旧缓存；`ps0.g.u()` 会继续寻找下一个帧头。它不会因一个孤片终止整条连接的协议接收。

0.2.1 将传输流重组和查询归属分开处理：

- 通知在订阅期间立即交给接收方；所有命令字节都持续进入同一个连接内的解析器，不等待查询提交。
- `markQuerySubmitted()` 只标记边界，保留已经收到的字节及首片来源。查询前开始、查询后才完成的消息仍属于前置消息；完整前置能力消息只记入 `unsolicitedCapabilities` 诊断，不算本次查询成功。
- 在有界接收范围内处理孤片、序号间断、新首片替代、无关主动消息和坏帧，重新寻找有效消息边界。坏 CRC 或不合法 protobuf 不会因容错而成为有效能力应答。
- 能力消息只有在查询提交后开始、且通过完整校验，才进入查询结果。协议未提供事务 ID，因此报告仍明确这种时间归属不能证明严格的一问一答关系。
- 文件通道单独计数，不混入命令重组，不解析、保存或确认文件载荷。

报告 schema 3 增加命令／文件各自的通知数、前置通知数和字节数，以及最近 **32 条帧结构和解析结果元数据**；不保存原始 payload。单次协议会话的累计接收预算为 **4096 次通知 / 256 KiB**，替代旧版合并的 64 次通知上限。命令解析器另有 64 KiB 累计输入预算，以及 4 KiB 缓冲、512 字节帧体、1024 字节重组消息和 64 片上限；累计流量预算不等于允许同时缓存全部数据。

ATT 回调也独立记录：即使协议解析已结束，只要同一有效连接和对应写特征的回调随后到达，仍记录写入确认或错误，不覆盖既有协议结果。旧连接回调不能更新新会话；已导出的报告快照不会被事后改写。

这些修改解决可定位的接收缺陷。针对性回归及执行边界见 [验证方法](VALIDATION.md)。旧 0.2.0 报告无法验证修复后的行为；早前身份通过照片、18:03 能力失败截图及 18:46 连接失败报告属于不同连接，仍需各自对应的完整 JSON 核实具体交互。

## 4. 身份分支的静态依据与实表边界

分支入口为 `ot0.a.D()`：根据实际 `protocolVersion` 选择流程，并读取 `supportProtocol & 3`。不能在未收到应答前假定协议版本，或只凭版本号跳入某个加密分支。0.3.0 已将下列版本 3–5 分支接入 App；早前照片显示这块表的版本为 5、身份已通过，**尚无对应完整 JSON 可核实该轮实际选择的加密能力及详细交互**。18:03 能力失败与 18:46 GATT 连接失败的两轮都没有进入此流程。旧版本分支仍未实现。

### 版本 ≥ 3：本地身份检查

`D()` → `N()`；一代的主连接类型 4 和主 BLE 类型 3 均可进入下列本地流程：

| 阶段 | 消息与关键字段 | 检查及出处 |
| --- | --- | --- |
| 交换 nonce | `sid=1, cid=24`，`IdentityConsult.field1 randomNumber`，uint64 | `ot0.a.I()` 发送客户端时间值；`A()` 处理手表 nonce，顺序为客户端值、手表值 |
| 临时密钥派生 | `AESCipher.generatorKey(clientNonce, watchNonce)` → 16 字节 | 原生 `key_generator`；已静态恢复并用独立合成向量检查 |
| 随机挑战 | `sid=1, cid=25`，`IdentityCheck.field1 data` 为 4 字节随机值；field2 为加密封装 | `ot0.a.H()` 发送；`z()` 解密回复 field2，并按位取反后与原挑战比较 |

临时密钥派生使用两个 nonce、512 字节缓冲区、确定性洗牌及两次 MD5；原生实现中的常数、索引运算及 MD5 表已核对。第一轮结果参与第二轮输入，参数顺序不能交换。该函数没有云请求或厂商服务器秘密输入，不能因为实现位于原生库就称其不可恢复。

挑战封装为“一字节补零数 + AES-128 ECB 密文”，按 16 字节补零；已对齐时不额外补整块，不能替换为 PKCS#7。验证依据是返回挑战的变换结果，而不是收到任意通知。出处包括 `AESCipher`、`rt0.i.a()` 和 `libencrypt.so` 的 `key_generator`、`encrypt`、`_encrypt`。

已建立独立重建程序及合成测试向量来检查算法和格式的一致性，但它们**不是官方客户端或手表捕获的已知答案**。没有运行目标原生库；早前身份通过照片是实表界面证据，不能替代记录实际能力、分支及逐命令结果的完整诊断。

### 能力位要求加密时：RSA / AES-256

身份检查通过后，类型 4 / 3 在 `supportProtocol & 3 != 0` 时继续 `ot0.a.K()`；未置位时该分支可直接完成此层传输协商。

1. `sid=1, cid=36`，`RSAConsult`：本机生成 RSA-2048；field1 为位数，field2 为 256 字节大端无符号模数，field3 为大端公钥指数。
2. `sid=1, cid=37`，`AESConsult`：field1 为 RSA 加密的 AES 密钥，field2 为 IV，field3 为验证明文，field4 为验证密文，field5 为状态。`ot0.a.y()` 与 `st0.a.a()` 使用本地私钥及 `RSA/NONE/PKCS1Padding` 解密，预期得到 32 字节密钥和 16 字节 IV。
3. `AESCipher.e()/d()`、`ls0.b` 及原生 `encrypt256` / `decrypt256` 显示使用 AES-256 CTR，外层仍带补零长度前缀。解密验证值必须与明文一致。
4. 验证后发送同消息 `state=1`，再通过 `gt0.a` 设置后续加密传输，外层 control 加上 `0x40`。

这条静态路线中的密钥由本机或手表产生，没有发现必须从云端获取身份密钥的步骤。官方代码对最后状态写入的成功和错误回调均可标记协商完成；独立实现不应照抄该行为，写入失败必须保留失败状态。此处恢复出的算法和字段尚不能证明该实机 BLE 入口采用这条路线，更不能证明首次设置已结束。

### 版本 1 / 2：初次持久密钥路径仍需调查

`ot0.a.O()` / `P()` 的行为与新版本不同。上层 `HDM2Connect` 在缺少 `bleSecretMetadata` 时可通过 `devicemanager.util.t.a()` 本地生成 16 个 ASCII 字母数字，并经 `NodeApi.createBond`、`WearableApiManager.o()`、`ft0.b.j()`、`ot0.c.i()` 传入逻辑绑定标志和密钥。这里的 `createBond` 是该 SDK 的逻辑操作，不能等同系统蓝牙配对 API。

但旧版本分支中，主类型 4 / 3 会检查 `et0.a` 的已有持久密钥，缺少时返回 key-not-exist；它们并未在已检查的路径中自动使用新传入的密钥。类型 1 / 5 的 `KeyConsult`（`1,22`）和 `ShakeHand`（`1,21`）是另一组条件分支，不能通过伪装设备类型强行复用。

因此，若实机能力应答为旧版本，仍需进一步确认首次逻辑绑定和持久密钥的实际来源与时序。现有证据不足以声称所有版本都可完全离线绑定，也不足以声称一代必需不可获得的云密钥。

## 5. 身份成功之后还有独立 OOBE 业务

手机端 APK 可以说明调用顺序和字段，但没有提供手表确认界面的固件代码。以下消息不能混作一个“确认验证码”命令。0.3.0 未发送表内消息；0.4.0 仅主动发送开始设置及状态查询。

| sid, cid | 业务 | 调用及证据 |
| --- | --- | --- |
| `11,7` | 开始设置 | `TaskConnectDevice.D()` → `do.c.f()`；`StartSetting` 值为 1、2 |
| `11,11` | 查询首次设置状态 | `OobeBusiness.C()`、设备管理器 `j()` 发送空 protobuf；0.4.0 在开始设置完整写确认后发送一次 |
| `11,11` / `11,12` | 状态回应／通知 | `OobeBusiness.q()` 经 `devicemanagerimpl.util.h.f()` 过滤后解析 `SyncOOBEState.SyncState` |
| `11,6` | 云绑定成功结果 | `TaskBindDevice` 网络绑定成功后调用 `OobeHelper.f()`，日志命名 `sendCloudBindSuccess`；`ConnectResult` 含结果、同步状态、SSOID、ticket、accountNumber |
| `11,2` | 开始同步 | OOBE 消息构造中的 `startSync` |
| `11,3` | 同步结束成功 | OOBE 消息构造中的 `endSyncSuccess` |
| `11,9` | 完成同步 / 开始使用 | `finishSyncSuccess`；`ua0.d.l()` 日志为 `sendStartUse` |
| `11,1` | 佩戴手腕设置 | `CapabilityHand`，由 `HandSettingActivity.S8()` 调用；**不是身份握手** |

来源：`do.c`（JADX 输出可能标为 `p001do.c`）、`OobeHelper`、`OobeBusiness`、`TaskConnectDevice`、`TaskBindDevice` 及相应调用方。

### 本版开始请求、查询及状态的精确范围

`do.c.f()` 构造 `StartSetting.StartSettingData`，字段 1 `startSetting=1`、字段 2 `startSettingResult=2`，均为 int32，精确 protobuf 为 `08 01 10 02`。两个请求值是 APK 的固定构造值，不能将字段名中的 `Result` 理解为本 App 已收到设置成功。`OobeBusiness.C()` 原代码连续发送三次空 `11/11`；本版为一次有界查询，不自动重发或补发未知业务命令。

`SyncState` 的字段 1 `result`、字段 2 `deviceType`、字段 3 `oobeFrom` 均为 int32。`result` 没有独立枚举，不能把其数值当成 Android 或蓝牙通用错误码。另有 `OOBE_FROM` 枚举记录 `FROM_NORMAL=0` 与 `FROM_MIRGATE=1`（保留原拼写），本版仅保存收到的来源数值，不实现迁移流程。

| `result` | 0.4.0 的解释 | 静态依据与限制 |
| --- | --- | --- |
| `0` | 首次设置尚未开始 | `devicemanager.util.x.e()` 将非手环的 0 列为未完成 |
| `10...59` | 首次设置仍待完成 | 同一函数将 10 至 59 列为未完成；不为每个数字臆造步骤名 |
| `60` | 手表报告首次设置已完成 | `OobeHelper` 的断连处理专门检查状态 60；本版仍不认定云账号绑定完成 |
| 其他有效 int32 | 未识别，保留数值 | 不照搬原客户端对“未完成集合”的宽泛取反来宣告成功 |

这些事实分别见 APK 分析中的 `pair_messages.java`（`do.c.f()`）、`start_setting_proto.java`、`oobe_business.java`、`oobe_event_filter.java`、`sync_oobe_proto.java`、`oobe_state_util.java` 与 `oobe_helper.clean.java`；实现中的判断和报告模型见 [`OppoSetup`](../Sources/WatchLink/OppoSetup.swift) 与 [`OppoSetupSnapshot`](../Sources/WatchLink/OppoSetupSnapshot.swift)。

状态来源有两道时间边界：开始设置首片提交之前的状态不能推进本轮；开始之后但状态查询首片提交之前开始的消息，只记录为 `preQueryObservation`，即使其最后一片晚到或数值为 60 也不能完成本轮查询。查询后开始的状态还须等待查询全部 ATT 成功。空 `11/11` 与查询回显不可区分，因此不把空消息补成有效状态 0；字段合法性、重复字段、整数范围及资源上限仍须通过检查。

查询首片提交后固定观察 45 秒。进度消息不重置计时；到期后有有效待完成状态才记 `DEVICE_SETUP_PENDING`，只有查询前状态或没有有效状态则记超时。状态 60 可提前结束观察。所有情况下账号字段维持 `NOT_IMPLEMENTED`，至多保存 16 条数值观测，不保存业务原始载荷。

### 仍待查明的账号与最终使用步骤

`WatchOOBEOperator` 的状态 10 分支在条件满足时查询云端或本地已绑定记录；发送已绑定状态时从 `UserInfoHelper.AccountInfo` 取得真实用户名与 ticket，再调用 `OobeHelper.f()`。该静态路径说明账号业务与传输身份不同，**尚不能证明所有固件都允许完全离线首次激活，也不能证明这块表必须依赖已经不可用的服务**。

当前无法从手机代码确定哪条消息或哪组状态必然使六位码或手动配对画面消失。没有证据证明传输身份成功单独就足够，也没有证据证明云成功通知是退出该界面的唯一条件。0.4.0 不构造虚假的 SSOID、ticket 或云成功结果，不发送 `11/6`、`11/9`、重置 `1/18`，不把未核实的业务设备信息请求当成无参数查询。

## 6. 下一步需要的实机证据

下一轮应使用 **0.4.2 build 7**，导出 **schema 7** 的完整 JSON；导出文件名包含 `v0.4.2-b7-` 和时间，需与 `platform` 和 `generatedAt` 一起核对。先核对系统连接是否恢复；只有 GATT 建立后才检查能力查询，身份通过后才在同一前台连接中点击“继续首次设置”。优先核对：

1. `observations.gattFailure` 的阶段、错误域、错误码、标识和发生时间；与 `gattConnectionObservedThisAttempt`、`result` 一起读取。错误 14 的恢复需先处理对应系统配对记录，单次点重连不表示清理完成。
2. `capabilityQuery` 的排队、实际提交、完整确认次数与 `hasCapabilities`；`commandWrites.queryAttempt` 对应各次写入。核对是否在已有有效能力时停止新重试、是否受写确认或截止时间限制；不能仅从 `1/1` 分片确认认定能力成功。
3. 命令／文件的通知数和字节数、`decoderDiagnostics`、能力来源与终止错误。区分无命令通知、仅文件通知、空命令通知和已有字节但没有完整能力，不用旧版 30 次通知的数据代替本次结果。
4. `authentication.selectedCapabilities / capabilitySource / transportAuthenticated`，确认实际版本、能力来源及所需身份步骤；版本 5 不单独决定是否走加密分支。
5. `businessSessionState / businessEncrypted`，确认认证上下文是否成功移交、实际业务模式及结束原因。
6. `commandWrites` 中 `serviceID=11` 的 `commandID=7`、`11`，分别检查分片提交、确认及错误；ATT 全部成功不等同手表接受业务语义。
7. `initialSetup.preQueryObservation` 与 `latestObservation / observations` 的区别，核对 `result / deviceType / oobeFrom / source / encodedFieldNumbers`，以及开始请求和查询的独立写入结果。
8. 手表实际画面、确认操作和退出等待的时点。状态 0、10...59、未知值、超时或断开各自保留原始含义，不能统一改称“登录失败”；状态 60 也需要与手表可用性共同核验。

系统连接错误位于 `observations`，能力、身份和设置字段位于 `vendorProtocol`。早前照片支持继续推进身份后的业务验证，最新报告则要求先处理本轮系统配对错误并恢复 GATT；这些观测都尚不能给出完整离线使用或云端阻断的结论。若本版之后仍卡住，应先根据新报告确定实际阶段，再调查该阶段的写入、接收、账号、设备信息或同步缺口，不能用伪造完成标记跳过证据。

## 7. 可追溯来源

### 用户提供的 APK

| 项目 | 值 |
| --- | --- |
| 包名 | `com.heytap.health` |
| 版本 | `4.22.11_8c76bdd_250530` |
| APK SHA-256 | `5b9ce81310236a3c02a603f4032ab9bc9ad482e95abcc1a654aeef4c31933ce1` |
| 原生库 | `lib/arm64-v8a/libencrypt.so` |
| 原生库 SHA-256 | `f7b7be63e26a6777f7a325d5f657ba9be8d98e892464163ee605589fd056b8ac` |

类和方法标识针对这一 APK 版本，混淆名在其他版本中可能改变。传输与身份依据主要来自 classes18 的 `ht0` / `it0` / `ps0` / `ot0`、`ConsultProto` 及加密封装；查询重试见 `ot0.a.M() / Q() / D()`、其超时 Runnable 与 `nd0.b.SCORLL_DELAYED=2000` 的 DEX 值，重连延迟见 `GattConnection.E() / F() / G()`。原生 KDF 定位为该 ARM64 库中的 `key_generator`（虚拟地址 `0x3784–0x3ab4`），其 MD5 辅助函数位于 `0x3ab8–0x3d38`。本文记录独立归纳的事实和必要协议常量，不附带完整反编译源代码或原 APK。

### Apple 官方文档

- `didConnect` 的连接成功语义：<https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate/centralmanager(_:didconnect:)>
- `CBPeripheral.state` 的连接状态语义：<https://developer.apple.com/documentation/corebluetooth/cbperipheral/state>
- Central manager delegate 的连接、发现与断开回调：<https://developer.apple.com/documentation/corebluetooth/cbcentralmanagerdelegate>
- Bluetooth 安全、配对及 bonding 概念：<https://support.apple.com/en-ie/guide/security/sec82597d97e/web>
- 对端配对信息移除错误：<https://developer.apple.com/documentation/corebluetooth/cberror-swift.struct/code/peerremovedpairinginformation>
- 系统取消配对的“忽略此设备”入口：<https://support.apple.com/zh-cn/105108>
- 已连接配件的取消配对／重新配对排查步骤：<https://support.apple.com/en-au/111804>
- CoreBluetooth 的取消连接接口：<https://developer.apple.com/documentation/corebluetooth/cbcentralmanager/cancelperipheralconnection%28_%3A%29>
- AccessorySetupKit 管理与移除配件的范围：<https://developer.apple.com/videos/play/wwdc2024/10203/>
