# 一代手表连接 · iOS

面向国行 OnePlus Watch 一代的原生 iOS 连接验证 App，当前版本 **0.3.0（build 4）**。对应安卓项目：[apple1day/mywatch](https://github.com/apple1day/mywatch)。

**本版从协议能力查询继续到真实传输身份认证：根据手表实际回应选择版本 3–5 的随机值交换、加密挑战和必要的 RSA/AES 协商。业务账号绑定、首次设置、健康同步和手机通知同步尚未实现。身份认证通过不等于手表已激活，也不保证退出配对画面。**

## 这次会实际执行什么

1. 扫描并选择设备，建立 GATT 连接，读取标准设备信息。
2. 订阅 APK 已核实的命令通知和可选文件通知，提交传输能力查询 `1/1`。
3. 查询写入得到完整 ATT 确认，并获得实际完整能力消息后，选择身份流程。有效的查询前主动能力也可以作为版本依据，但报告明确标为 `PRE_QUERY_OBSERVATION`，不会伪称查询应答。同一连接的矛盾能力参数会终止验证。
4. 协议版本 3–5：发送 `IdentityConsult 1/24`，用手机与手表的随机值派生临时密钥，再发送 `IdentityCheck 1/25`。只有解密后的反码挑战与本次随机挑战一致，才标记身份校验通过。
5. 手表的 `supportProtocol & 3` 非零时，继续发送 RSA-2048 公钥 `1/36`，接收 `AESConsult 1/37`，解密并验证 AES-256 会话证明，最后发送 `1/37 state=1`。最后一条消息的全部 ATT 分片也必须确认成功。
6. 显示实际结果并导出诊断。无后续业务命令，临时密钥和挑战不会持久保存。

版本 1–2 会明确停止并报告旧密钥路径尚未适配；不会假定协议版本 5，也不会伪装成其他型号来套用旧流程。原厂协议没有请求事务 ID，消息起点用于排除旧片，当前随机挑战用于验证身份回应。

算法依据来自用户提供的欢太健康 APK 静态分析。密码学与协议测试使用标准或独立合成向量，**不是官方客户端抓包，也不能替代实体手表验证**。详见 [绑定问题分析](docs/BINDING_ANALYSIS.md)。

## 界面状态现在分开显示

“已选择的设备”只说明操作对象；不再使用固定成功勾号。连接验证区分别显示：

| 阶段 | 可以确认的事实 |
| --- | --- |
| 蓝牙通道 | GATT 是否连接 |
| 协议能力 | 是否取得完整校验通过的能力信息 |
| 传输身份 | 尚未开始、正在验证、已通过、失败或中断 |
| 业务绑定与首次设置 | 当前未实现 |

按钮会显示正在进行的具体阶段，结束后显示通过／失败／中断。每次连接只执行一轮验证，重试前先断开再重连，避免晚到的写入回调被误归给下一轮。

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

1. 确认首页版本为 **0.3.0**，保留手表现有数据，让手表亮屏并靠近手机。
2. 扫描、选择设备，点击 **连接 GATT 并读取标准信息**。
3. 在 **连接验证进度** 中点击 **验证连接与身份**。若出现系统配对弹窗，核对两端数字后确认。
4. 保持 App 在前台，观察是否进入随机值交换、身份挑战、加密协商等阶段；等待最终通过或明确错误。
5. 点击 **导出本次验证结果** 或底部 **导出诊断报告 → 保存 JSON**。报告应显示版本 `0.3.0`、构建 `4`、`schemaVersion: 4`。
6. 将完整 JSON 发回开发对话，并说明手表画面是否变化。即使手表仍在配对画面，身份阶段的真实结果也能确定下一步。

通知订阅每步最多等待 90 秒；每个 ATT 写入回调最多 20 秒；每条身份命令从实际首片提交起最多等待 45 秒。收到回复早于 ATT 回调时会保留回复，等待整条命令所有写入确认，不会提前继续。每个 TL 帧最多 20 字节，并同时受手表声明和实际 ATT 限额限制；分片与跨命令发送均遵守协商间隔。

进入后台会结束本轮验证并释放连接。系统授权弹窗造成的短暂 inactive 不算进入后台。导出先生成状态快照，后续事件不会改写已保存报告。

## 报告中的关键字段

| 字段 | 含义 |
| --- | --- |
| `vendorProtocol.status` | 整轮查询／认证的当前或终止状态 |
| `vendorProtocol.capabilities` | 提交查询后开始的完整能力消息；不等同严格事务关联 |
| `decoderDiagnostics.unsolicitedCapabilities` | 查询前开始的完整主动能力 |
| `authentication.selectedCapabilities / capabilitySource` | 本轮身份流程实际采用的能力及来源 |
| `authentication.phase / status / error` | 身份阶段、结果和具体失败原因 |
| `authentication.identityVerified` | 当前随机挑战是否校验通过 |
| `authentication.keyExchangeVerified` | 如需要，RSA/AES 会话证明是否校验通过 |
| `authentication.transportAuthenticated` | 所需身份步骤及最后写入是否全部完成 |
| `commandWrites` | 每条逻辑命令已提交／已确认的 ATT 分片数及错误 |
| `attWriteAcknowledged` | 仅原始能力查询的 ATT 结果；后续命令分别记录 |
| `accountBinding` | 本版一直为 `NOT_IMPLEMENTED` |

报告不包含身份随机值、挑战、RSA 私钥、会话密钥、验证码或原始私有消息。只保留能力、阶段、计数和最多 32 条帧头元数据。设备名称和标准设备信息仍可能识别设备。应用不包含账号登录、分析 SDK、广告或网络上传功能。

## 平台与剩余工作

原厂 Android 一代分支使用两个自定义 secure RFCOMM 通道，普通 iOS 公共 API 没有直接对应实现。用户实表同时暴露了与 APK 一致的 BLE 命令服务，因此当前继续验证这条 BLE 路径；其存在不能证明固件支持完整 BLE 首次绑定。[平台分析](docs/IOS_COMPATIBILITY.md) 区分了这两类证据。

0.2.1 的持续收流、分片恢复、CRC 与来源校验均保留。0.3.0 新增身份握手，但不会发送账号云绑定成功、开始设置、同步完成、开始使用、解绑或固件写入消息。下一阶段需要依据实表身份结果继续研究业务设备信息、账号绑定及首次设置，不能用伪造的成功标记代替设备确认。

## 构建与检查

[GitHub Actions](https://github.com/apple1day/mywatch-apple/actions) 执行无签名设备构建、单元测试、模拟器界面测试并保存截图。检查范围见 [验证说明](docs/VALIDATION.md)。

- `WatchLink-iOS-device-build`：无签名 iPhone/iPad `.app` ZIP 和校验信息。
- `WatchLink-iOS-simulator-build`：测试通过后的模拟器 `.app` ZIP。
- `WatchLink-test-results`：测试结果、日志和界面截图。

这些产物不是可直接安装的已签名 IPA。实机安装仍需 Xcode 使用自己的开发签名；编译和自动测试通过不表示手表已绑定。
