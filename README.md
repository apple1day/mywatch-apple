# 一代手表连接 · iOS

面向国行 OnePlus Watch 一代的 **iPhone / iPad 连接诊断版**，版本 `0.1.0`。对应安卓项目：[apple1day/mywatch](https://github.com/apple1day/mywatch)。

**重要边界：这个 iOS 版本提供 BLE / GATT 诊断，不能直接复现安卓版本的一代自定义 RFCOMM 双通道。原厂绑定、激活、健康同步、通知、表盘和固件升级尚未实现；实体手表互通尚待验证。**

## 已实现的功能

- 原生 SwiftUI 中文界面，iOS / iPadOS 16.0 及以上，无第三方运行时依赖。
- 用户主动启动蓝牙，有限时扫描、设备去重、一代名称候选筛选与其他设备入口。
- CoreBluetooth GATT 连接、服务和特征发现、标准电量／型号／固件／软件版本／制造商只读查询。
- 连接取消、超时、设备切换、蓝牙状态变化与后台释放处理。
- 本地 JSON 报告、连接事件记录，以及导出前固定状态快照。
- 会话匿名化的外设标识，不导出原始 peripheral UUID 或广播载荷。
- Mac 工程生成脚本、签名设置保留、单元检查、模拟器 UI 检查和 GitHub Actions 构建。

本应用不包含登录、分析 SDK、广告或网络上传功能。界面中的项目链接会在用户点击后交给浏览器打开。

## 为什么不能完全等同安卓版

上传的欢太健康 APK 显示，国行一代的已知主连接路径使用两个自定义 **secure RFCOMM** 服务。安卓版本按该路径尝试建立两个 Socket。

Apple 的 CoreBluetooth 虽支持 BLE 和部分经典蓝牙访问，其经典蓝牙接口提供的是 **GATT over BR/EDR**。这与按服务 UUID 打开任意 RFCOMM Socket 不同。ExternalAccessory 则面向具备相应 MFi 协议支持的配件；本项目没有这块国行一代的 MFi 通道或厂商授权资料。

因此，iPhone 能发现或连接某个 GATT 设备，只能证明对应阶段成功，不能直接说明一代主通道、原厂绑定或健康同步已经恢复。也不能把“没有扫描到”直接解释为手表损坏或彻底不兼容。

详细技术依据见 [iOS 平台与协议说明](docs/IOS_COMPATIBILITY.md)。

| 能力 | 安卓验证版 | 本 iOS 版 |
| --- | --- | --- |
| 附近 BLE / GATT 设备发现 | 有 | 有 |
| 标准电量与设备信息 | 设备提供时可读取 | 设备提供时可读取 |
| 一代已知 RFCOMM 主／数据通道 | 已实现连接尝试，待实表 | 普通 iOS 公开接口无直接对应实现 |
| 系统已配对设备列表／主动经典蓝牙配对请求 | 有 | 未提供，不将 GATT 设备列表冒充配对列表 |
| 本地诊断报告 | 有 | 有 |
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
5. 查看状态和设备实际返回的内容，再点击 **导出诊断报告 → 保存 JSON**。

报告可发回开发对话，用于判断是否存在 iOS 能访问的 GATT 服务。对标准信息没有返回值时，应用保留缺失或失败状态，不填入猜测的电量、型号或固件。

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
| `Sources/WatchLink/` | 原生界面、蓝牙状态机、数据模型与报告 |
| `Tests/` | 模型测试和不依赖手表的 UI 检查 |
| `project.yml` | XcodeGen 工程定义 |
| `setup.sh`、`scripts/` | 环境检查、签名配置保留、CI 构建 |
| `Config/`、`Resources/` | 构建配置、权限说明、隐私清单与资源 |
| `docs/` | 平台限制与验收说明 |

后续优先依据实表报告确认 GATT 能力；只有拿到真实服务及交互证据，才能决定是否有适合 iOS 的业务通路。不能仅把安卓的 RFCOMM UUID 改写成 GATT UUID 来实现同一协议。
