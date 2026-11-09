# 一代手表连接 · iOS

面向国行 OnePlus Watch 一代的原生 iOS 连接验证 App，当前版本 **0.4.2（build 7）**。对应安卓项目：[apple1day/mywatch](https://github.com/apple1day/mywatch)。

**本版识别 GATT 连接阶段的系统错误，在连接按钮附近显示失败原因和恢复步骤，并把“协议尚未开始”与“正在等待能力回包”分开。原有的能力查询重试、传输身份认证及首次设置开始／状态观察继续保留。账号登录与云绑定、完整首次设置、健康同步和手机通知同步仍未实现。身份通过、写入成功、手表报告设置完成分别记录，均不被自动当作账号绑定成功。**

最新收到的 **0.4.1 / build 6 / schema 6** 报告生成于北京时间 **18:47:02**：18:46:11 请求 GATT，18:46:12 收到 `CBErrorDomain / 14`，本轮未建立连接，服务与标准信息为空、能力查询提交次数为 0。该错误对应系统报告的 `peerRemovedPairingInformation`，表示对端移除了配对信息；报告不能确定是谁或什么操作造成的。0.4.1 的查询重试在这轮尚未执行，不能将这个连接阶段错误归因于查询命令。此前身份通过照片、18:03 的能力等待失败和 14:11 的旧分片报告属于其他轮次，不能合并解释为同一次故障。

## 连接立即失败，提示错误 14 时

现有 **0.4.1** 就可以先按下面步骤处理，无需等待安装新版本。此操作只针对用户确认的对应手表配对记录：

1. 打开 iPhone **设置 → 蓝牙**，找到与本次手表对应的 **OnePlus Watch** 记录，点右侧 **ⓘ → 忽略此设备**。
2. 让手表保持配对页面并靠近手机。
3. 返回 Watch Link，**重新扫描**，重新选中手表，再点击 **连接 GATT 并读取标准信息**。
4. GATT 和标准检测完成后，点击 **验证连接与身份**；如出现系统配对提示，核对两端数字并确认。

若系统蓝牙列表没有对应记录，或处理后仍失败，保留新的完整报告和手表画面继续核查。App 当前通过 CoreBluetooth 连接，不能代替用户清除系统保存的这条配对记录。0.4.2 提供准确提示和报告，不将显示恢复步骤、点击重试或重新扫描当作系统配对已经修复。错误定义与平台范围见 [平台说明](docs/IOS_COMPATIBILITY.md)。

## 这次会实际执行什么

1. 扫描并选择设备，建立 GATT 连接，读取标准设备信息。
2. 订阅 APK 已核实的命令通知和可选文件通知，提交原有传输能力查询 `1/1`。没有完整有效能力时，在每次实际提交至少 2 秒、且该次全部 ATT 分片已确认后重发相同查询；首发加最多 3 次重试，共最多 4 次。取得完整有效能力后停止安排后续重试，当前已排队或提交的查询仍须完成写入确认。
3. 查询写入得到完整 ATT 确认，并获得实际完整能力消息后，选择身份流程。有效的查询前主动能力也可以作为版本依据，但报告明确标为 `PRE_QUERY_OBSERVATION`，不会伪称查询应答，首发查询仍须提交并确认。同一连接的矛盾能力参数会终止验证。重试不清空接收器、不移动首次查询的消息归属边界，也不重置首次查询起算的 45 秒总窗口。
4. 协议版本 3–5：发送 `IdentityConsult 1/24`，用手机与手表的随机值派生临时密钥，再发送 `IdentityCheck 1/25`。只有解密后的反码挑战与本次随机挑战一致，才标记身份校验通过。
5. 手表的 `supportProtocol & 3` 非零时，继续发送 RSA-2048 公钥 `1/36`，接收 `AESConsult 1/37`，解密并验证 AES-256 会话证明，最后发送 `1/37 state=1`。最后一条消息的全部 ATT 分片也必须确认成功。
6. 所需身份步骤和最终写入全部成功后，将业务会话一次性交给当前连接。按手表实际能力使用明文或已协商的 AES 会话，不因协议版本为 5 就假定必须加密；身份挑战材料释放，必要的业务密钥只留在内存。
7. 用户点击 **继续首次设置** 后，发送 `StartSetting 11/7`，protobuf 为 `08 01 10 02`。等整条命令的全部 ATT 分片确认后，再发送空 protobuf 的 `SyncOOBEState 11/11` 查询。
8. 查询完整写入后，处理真实 `11/11` 或 `11/12` 状态。状态 `0` 表示尚未开始，`10...59` 表示仍待完成，`60` 仅记为“手表报告首次设置已完成”；其他数值保留为未识别。查询首片实际提交后最多观察 45 秒，进度通知不会延长这个期限。观察结束或失败后释放业务会话。

版本 1–2 会明确停止并报告旧密钥路径尚未适配；不会假定协议版本 5，也不会伪装成其他型号来套用旧流程。原厂协议没有请求事务 ID，消息起点用于排除旧片，当前随机挑战用于验证身份回应；报告中的查询轮次只关联发送和 ATT 结果，不能严格把能力回包归属到某一次重试。

算法依据来自用户提供的欢太健康 APK 静态分析。密码学与协议测试使用标准或独立合成向量，**不是官方客户端抓包，也不能替代实体手表验证**。详见 [绑定问题分析](docs/BINDING_ANALYSIS.md)。

## 界面状态现在分开显示

“已选择的设备”只说明操作对象；不再使用固定成功勾号。连接验证区分别显示：

| 阶段 | 可以确认的事实 |
| --- | --- |
| 蓝牙通道 | GATT 是否连接；连接阶段失败另显示系统原因和恢复步骤 |
| 协议能力 | 尚未开始、等待能力消息、已取得，或本轮未取得／已中断；未启动查询时不显示为正在等待结果 |
| 传输身份 | 尚未开始、正在验证、已通过、失败或中断 |
| 首次设置 | 未开始、正在观察、仍待完成、手表报告完成、失败或中断 |
| 账号绑定 | 当前一直为 `NOT_IMPLEMENTED` |

按钮会显示正在进行的具体阶段，灰色本身不是成功标志。身份通过后在同一连接中继续首次设置；每次连接各执行一轮，结束后重试须先断开再重连，避免晚到回调被误归给下一轮。查询前开始的设置状态只作单独观测，不用它宣告本次查询或设置成功。

开始验证后，能力查询区始终显示命令与文件收包数，包括 **0 条**，并显示实际提交的查询次数。查询发送确认、收到通知和解析出有效能力是不同事实；能力阶段失败会说明当前属于没有命令通知、仅有文件通知、空命令通知，还是已有命令字节但未取得完整有效能力。它们用于缩小排查范围，不直接判定蓝牙配对、账号登录或手表固件已经失败。

## 在已有 Mac 项目中更新

在 `mywatch-apple` 目录执行：

```bash
git pull --ff-only
bash setup.sh
```

首次安装：

```bash
git clone https://github.com/apple1day/mywatch-apple.git
cd mywatch-apple
bash setup.sh
```

需要完整 Xcode、iOS SDK 和 XcodeGen。脚本会生成并打开 `WatchLink.xcodeproj`；XcodeGen 缺失而 Homebrew 可用时会安装。正常重新生成时，已有 Team、Bundle ID 和签名配置会保留到被 Git 忽略的本地设置。

在 Xcode 中选择 WatchLink target、自己的签名 Team 和连接的 iPhone，点击 **Run**。默认 Bundle ID 为 `com.anxiong.watchlink.ios`，支持 iOS / iPadOS 16.0 及以上，无第三方运行时依赖。本仓库不包含个人 Apple 证书或描述文件。

## 本次实表验证步骤

1. 确认首页版本为 **0.4.2**，导出页构建为 **7**；让手表亮屏并靠近手机。若之前出现 `CBErrorDomain / 14`，先完成上面的系统配对记录处理步骤。
2. 扫描、选择设备，点击 **连接 GATT 并读取标准信息**。
3. 在 **连接验证进度** 中点击 **验证连接与身份**。若出现系统配对弹窗，核对两端数字后确认。
4. 保持 App 在前台，观察查询次数以及命令／文件收包数。未取得能力时，本轮会按写确认和时间条件最多发 4 次相同查询，首次查询起算的总等待仍为 45 秒。若失败，直接导出本次结果；若身份认证通过，继续使用这次连接，点击 **继续首次设置**。业务会话已中断时按提示重新连接并验证身份。
5. 观察手表是否显示新的确认、退出配对画面或进入主界面；App 会显示真实状态及本轮观察结果。没有状态变化也请保留报告，不据此直接认定是账号登录失败。
6. 点击 **导出本次验证结果** 或底部 **导出诊断报告 → 保存 JSON**。核对导出界面的版本和生成时间；文件名应包含 `v0.4.2-b7-` 和时间，JSON 应显示 `platform.appVersion: "0.4.2"`、`appBuild: "7"`、`schemaVersion: 7`。若 GATT 尚未连接，先核对 `observations.gattFailure`；不要把未开始的查询计数 0 当作能力查询超时。
7. 将完整 JSON 发回开发对话，并说明手表在点击前后显示什么、是否出现确认、是否能实际进入主界面。即使 App 显示状态 `60`，也仍需核对手表画面与可用功能。

通知订阅每步最多等待 90 秒；每个 ATT 写入回调最多 20 秒；整轮能力查询从首次实际提交起最多等待 45 秒，重试不延长。每条身份或首次设置命令从实际首片提交起最多等待 45 秒。设置查询的这 45 秒同时是固定观察窗，不因连续状态消息重新计时。回复早于 ATT 回调时会有限缓存，等待整条命令所有写入确认，不提前推进。每个 TL 帧最多 20 字节，并同时受手表声明和实际 ATT 限额限制；分片与跨命令发送均遵守协商间隔。一轮逻辑命令预算为 10 条，覆盖最多 4 次查询、4 条身份消息及 2 条首次设置消息。

进入后台、断连或切换设备会结束本轮协议工作并使业务会话失效；已有身份及设置观测保留。系统授权弹窗造成的短暂 inactive 不算进入后台。导出先生成状态快照，后续事件不会改写已保存报告。导出页的版本、构建、schema 和时间来自该快照；时间显示本地 UTC 偏移。文件名为 `WatchLink-iOS-v版本-b构建-生成时间-随机短后缀.json`，同一快照保持稳定，不包含设备标识；缺失元数据时显示未知，不用当前 App 信息冒充。

## 报告中的关键字段

| 字段 | 含义 |
| --- | --- |
| `observations.gattFailure` | 本轮系统连接／断开回调的结构化错误：`stage / domain / code / occurredAt / errorIdentifier`；配对信息移除为 `PEER_REMOVED_PAIRING_INFORMATION`，不由错误码数字单独判定 |
| `vendorProtocol.status` | 查询、认证或首次设置的当前或终止状态 |
| `vendorProtocol.capabilityQuery` | 能力查询的 `status / queuedAttempts / submittedAttempts / acknowledgedAttempts / currentAttempt / maximumAttempts / retryDelayMilliseconds / hasCapabilities`；轮次从 1 起，最多 4 次，计数分别表示已排队、实际提交和完整确认 |
| `vendorProtocol.capabilityTimeoutReason` | 能力阶段超时的观测分类；与 `error.phase=PROTOCOL_RESPONSE / code=1001` 一起读取，不能单独作为根因 |
| `commandNotificationActivation / fileNotificationActivation` | 通知开启过程：例如已处于开启状态 `ALREADY_ENABLED`、请求开启 `ENABLE_REQUESTED`、回调确认 `ENABLE_CONFIRMED`；仅增加诊断，未改变订阅行为 |
| `commandNotificationCallbackCount / fileNotificationCallbackCount` | 两个通道的通知状态回调数；不同于实际数据通知数 |
| `vendorProtocol.capabilities` | 提交查询后开始的完整能力消息；不等同严格事务关联 |
| `decoderDiagnostics.unsolicitedCapabilities` | 查询前开始的完整主动能力 |
| `authentication.selectedCapabilities / capabilitySource` | 本轮身份流程实际采用的能力及来源 |
| `authentication.phase / status / error` | 身份阶段、结果和具体失败原因 |
| `authentication.identityVerified` | 当前随机挑战是否校验通过 |
| `authentication.keyExchangeVerified` | 如需要，RSA/AES 会话证明是否校验通过 |
| `authentication.transportAuthenticated` | 所需身份步骤及最后写入是否全部完成 |
| `businessSessionState / businessEncrypted` | 业务会话是否就绪、运行、结束或失效，以及实际是否加密；位于 `vendorProtocol` |
| `initialSetup.status / phase / error` | 首次设置阶段、结果及失败原因；位于 `vendorProtocol` |
| `initialSetup.startWriteAcknowledged / queryWriteAcknowledged` | `11/7` 与 `11/11` 是否分别取得全部 ATT 写确认 |
| `initialSetup.preQueryObservation` | 查询前开始的主动状态；不能代替本轮查询后的观测 |
| `initialSetup.latestObservation / observations` | 通过本轮来源及写入门禁的状态，含 `result / deviceType / oobeFrom / source`；历史最多 16 条 |
| `commandWrites` | 每条逻辑命令的 `serviceID / commandID / stage / encrypted`、已提交／已确认的 ATT 分片数及错误；能力查询另带从 1 起的 `queryAttempt` |
| `attWriteAcknowledged` | 仍只表示首次能力查询的 ATT 结果，不改为重试汇总；各次查询见 `capabilityQuery` 与 `commandWrites` |
| `commandNotificationCount / fileNotificationCount` | 两个通道实际通知数；结合各自字节数、空通知及解析诊断区分没有回包和未解析出完整能力 |
| `accountBinding` | 本版一直为 `NOT_IMPLEMENTED` |

表中未写完整路径的认证、设置和命令字段均位于 `vendorProtocol`。顶层 `capabilities.initialSetup` 另说明本版提供的是实验性的开始请求与状态观察，不表示运行已经成功。`accountBinding` 在能力、协议和首次设置报告中始终为 `NOT_IMPLEMENTED`。

报告不包含身份随机值、挑战、RSA 私钥、会话密钥、验证码、原始私有消息或密文载荷。只保留能力、阶段、数值状态、计数和最多 32 条帧头元数据。设备名称和标准设备信息仍可能识别设备。应用不包含账号登录、分析 SDK、广告或网络上传功能。

## 平台与剩余工作

原厂 Android 一代分支使用两个自定义 secure RFCOMM 通道，普通 iOS 公共 API 没有直接对应实现。用户实表同时暴露了与 APK 一致的 BLE 命令服务，因此当前继续验证这条 BLE 路径；其存在不能证明固件支持完整 BLE 首次绑定。[平台分析](docs/IOS_COMPATIBILITY.md) 区分了这两类证据。

0.2.1 的持续收流、分片恢复、CRC 与来源校验，以及 0.3.0 的身份握手均保留。0.3.0 在身份之后停止；0.4.0 新增的业务发送仅为 `11/7` 开始设置和 `11/11` 状态查询。0.4.1 为原有能力查询补上有界重试与诊断；0.4.2 增加连接错误恢复提示、结构化报告及未开始阶段的准确显示，不自动清除系统配对或改变查询协议。本版不发送 `11/6` 云绑定成功、`11/9` 结束设置／开始使用、同步完成、解绑或固件消息，也不构造虚假的 SSOID 或 ticket。

能否在这块固件上完成不依赖云账号的使用，还需要真实状态和手表界面共同验证。现有证据既不足以保证完整离线激活，也不足以认定手表已经无法使用。下一步应依据本版的实际回复定位尚缺的业务流程。

## 构建与检查

[GitHub Actions](https://github.com/apple1day/mywatch-apple/actions) 执行无签名设备构建、单元测试、模拟器界面测试并保存截图。检查范围见 [验证说明](docs/VALIDATION.md)。

- `WatchLink-iOS-device-build`：无签名 iPhone/iPad `.app` ZIP 和校验信息。
- `WatchLink-iOS-simulator-build`：测试通过后的模拟器 `.app` ZIP。
- `WatchLink-test-results`：测试结果、日志和界面截图。

这些产物不是可直接安装的已签名 IPA。实机安装仍需 Xcode 使用自己的开发签名；编译和自动测试通过不表示手表已绑定。
