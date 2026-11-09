# 一代手表连接 · iOS

面向国行 OnePlus Watch 一代的 **iPhone / iPad 连接与协议诊断版**，版本 `0.2.0`。对应安卓项目：[apple1day/mywatch](https://github.com/apple1day/mywatch)。

**当前范围：0.2.0 在标准 GATT 检测后，新增已核实 BLE 通道的通知订阅与一次传输能力查询。它尚未执行后续身份认证、业务绑定、激活或健康同步，不能保证手表退出“请在手机上确认”。**

## 手机已确认验证码，手表仍等待

实表报告已证实：GATT 保持连接，7 个服务／14 个特征可见，标准设备信息可读取。0.1.0 到这里就结束了，没有订阅手表的命令通知，也没有发送原厂协议协商。报告中的 `vendorAuthentication` 和 `accountBinding` 均为 `NOT_IMPLEMENTED`。

系统验证码由 iOS 和手表的蓝牙协议栈处理。上述标准读取不能证明持久配对已成功，也不能代替原厂身份认证与业务绑定。此次没有断连、后台释放或读取超时的证据，因此不能靠增加读取超时就认定修复。

实表还确认了与原厂 APK 一致的另一组 BLE 命令特征。0.2.0 增加 **“检查手表协议”**：先启用已核实的通知，再发送一次已还原的 `TransportConsult` 请求，记录真实回应的版本、帧长、传输单元及失败阶段。**收到能力回应仍显示“认证和绑定尚未完成”，不会自动继续未验证的身份／绑定流程。**

完整分析、通道方向和协议证据见 [绑定问题分析](docs/BINDING_ANALYSIS.md)。

## 已实现的功能

- 原生 SwiftUI 中文界面，iOS / iPadOS 16.0 及以上，无第三方运行时依赖。
- 用户主动启动蓝牙，有限时扫描、设备去重、一代名称候选筛选与其他设备入口。
- CoreBluetooth GATT 连接、服务和特征发现、标准电量／型号／固件／软件版本／制造商只读查询。
- 精确匹配 OPPO_AT 服务和特征，串行启用命令与可选文件通知；只向命令特征发送一次传输能力查询。
- 分开记录通知状态、ATT 写确认和设备协议回应；支持有界帧重组、CRC16 校验以及能力 protobuf 解析。
- 不把回显、损坏帧、未知命令或部分消息当作成功回应；系统配对状态明确标记为 App 无法直接观测。
- 连接取消、超时、设备切换、蓝牙状态变化与后台释放处理。
- 本地 JSON 报告、连接事件记录，以及导出前固定状态快照。
- 会话匿名化的外设标识，不导出原始 peripheral UUID 或广播载荷。
- Mac 工程生成脚本、签名设置保留、单元检查、模拟器 UI 检查和 GitHub Actions 构建。

本应用不包含登录、分析 SDK、广告或网络上传功能。界面中的项目链接会在用户点击后交给浏览器打开。

## 为什么不能完全等同安卓版

上传的欢太健康 APK 显示，国行一代的已知主连接路径使用两个自定义 **secure RFCOMM** 服务。安卓版本按该路径尝试建立两个 Socket。

Apple 的 CoreBluetooth 虽支持 BLE 和部分经典蓝牙访问，其经典蓝牙接口提供的是 **GATT over BR/EDR**。这与按服务 UUID 打开任意 RFCOMM Socket 不同。ExternalAccessory 则面向具备相应 MFi 协议支持的配件；本项目没有这块国行一代的 MFi 通道或厂商授权资料。

Android 选择 RFCOMM 的静态证据不能排除手表同时开放 BLE 业务入口。用户的新报告已确认相关 BLE 特征存在，但尚未提供该通道的业务回包。0.2.0 正是用于取得第一条协议能力证据；GATT 连接或一次能力回应均不能直接说明原厂绑定、激活或健康同步已恢复。

详细技术依据见 [iOS 平台与协议说明](docs/IOS_COMPATIBILITY.md)。

| 能力 | 安卓验证版 | 本 iOS 版 |
| --- | --- | --- |
| 附近 BLE / GATT 设备发现 | 有 | 有 |
| 标准电量与设备信息 | 设备提供时可读取 | 设备提供时可读取 |
| 一代已知 RFCOMM 主／数据通道 | 已实现连接尝试，待实表 | 普通 iOS 公开接口无直接对应实现 |
| 系统已配对设备列表／主动经典蓝牙配对请求 | 有 | 未提供，不将 GATT 设备列表冒充配对列表 |
| 本地诊断报告 | 有 | 有 |
| OPPO_AT 传输能力查询 | 未实现 | 0.2.0 已实现，待实表回包 |
| 原厂绑定、通知、健康同步 | 未实现 | 未实现 |

## 在 Mac 上生成工程并安装

需要完整 Xcode、其 iOS SDK，以及可用的 XcodeGen。`setup.sh` 会检查环境；XcodeGen 缺失时，如果已安装 Homebrew，会使用 Homebrew 安装。

```bash
git clone https://github.com/apple1day/mywatch-apple.git
cd mywatch-apple
bash setup.sh
```

脚本会生成并打开 `WatchLink.xcodeproj`。接着：

1. 在 Xcode 的 **Settings → Accounts** 中添加你的 Apple 账号。
2. 选择 **WatchLink target → Signing & Capabilities**，选择自己的 **Team**，使用自动签名。
3. 连接 iPhone，在 Xcode 顶部选择该设备；按设备提示完成信任和开发者模式设置。
4. 点击 **Run** 安装运行。默认 Bundle ID 为 `com.anxiong.watchlink.ios`，如账号提示标识冲突，可在 Xcode 修改。

重新执行 `bash setup.sh` 前，脚本会读取现有工程的签名设置并保留到被 Git 忽略的本地配置。Team、Bundle ID 和相关签名选项不会因为正常重新生成而丢失。可以用 `bash setup.sh --no-open` 只生成工程。

完整项目可由源码重建；本仓库不包含个人 Apple 证书或预置描述文件。

## 实表测试顺序

1. 保留手表现有绑定和数据，让手表亮屏并靠近 iPhone。
2. 打开 App，点击 **扫描附近 BLE 设备**，允许蓝牙权限。
3. 查看一代名称候选；没有候选时打开 **显示其他设备**。名称只是筛选线索。
4. 选择设备，点击 **连接 GATT 并读取标准信息**。
5. 在 **配对与绑定** 中点击 **检查手表协议**，如出现系统配对弹窗，核对两端数字后确认。
6. 等待出现协议回应或错误，点击 **导出诊断报告 → 保存 JSON**。报告应显示 `appVersion: 0.2.0`、`schemaVersion: 2` 和 `vendorProtocol`。

每条 GATT 连接最多执行一次查询；重试前先断开并重连，以免旧请求回调被错当成新回应。订阅期间早到的通知单独计数，不追认为查询响应。只查询能力，不向文件、升级、解绑或控制特征写数据。

报告可发回开发对话，用于选择下一阶段身份认证路径。`vendorProtocol.capabilities` 是实际校验过的回应；`error.phase/domain/code/message` 用于定位订阅、写入、接收、协议校验或断连失败。`attWriteAcknowledged: false` 只表示没有观测到 ATT 确认；如果协议回应先到，不能把它单独解释为写入失败。标准信息未返回时保持缺失或失败状态。

离开前台进入后台会结束扫描、取消或断开连接；回到 App 后需手动重试。系统授权弹窗造成的短暂 inactive 不会被当作进入后台。导出时先固定报告，之后的断连不会改写该报告。

## 构建与验证

[查看 GitHub Actions](https://github.com/apple1day/mywatch-apple/actions)

CI 使用 macOS 与 Xcode，先完成并上传无签名真机目标构建，再执行纯模型测试和模拟器界面检查。检查范围和手动验收项目见 [验证说明](docs/VALIDATION.md)。

- `WatchLink-iOS-device-build`：无签名 iPhone/iPad 应用 ZIP、校验值和产物说明。
- `WatchLink-iOS-simulator-build`：测试通过后生成的模拟器应用 ZIP。
- `WatchLink-test-results`：测试结果、模拟器截图与构建日志。

CI 产物中的模拟器 `.app` 用于模拟器；无签名设备 `.app` ZIP 用于构建检查，安装到 iPhone 仍需要你的开发签名。它们不代表已经生成可直接侧载的已签名 IPA，也不代表实体手表测试通过。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/WatchLink/` | 原生界面、蓝牙状态机、能力查询传输与编解码、数据模型与报告 |
| `Tests/` | 模型测试和不依赖手表的 UI 检查 |
| `project.yml` | XcodeGen 工程定义 |
| `setup.sh`、`scripts/` | 环境检查、签名配置保留、CI 构建 |
| `Config/`、`Resources/` | 构建配置、权限说明、隐私清单与资源 |
| `docs/` | 平台限制与验收说明 |

下一阶段依据 0.2.0 的真实能力回应核对协议版本，继续验证身份校验及 OOBE 初始化。已有静态身份算法重建线索，不能将其写成已通过实表认证，也不能把云账户注册和本地传输认证混为一项。
