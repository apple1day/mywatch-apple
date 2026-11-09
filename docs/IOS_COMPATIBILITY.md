# 国行一代手表与 iOS 的连接边界

核查日期：2026-11-09（北京时间）。本文区分安卓安装包的静态证据、Apple 平台接口事实，以及尚待实体手表验证的部分。

## 已知设备路径

Android 项目 [apple1day/mywatch](https://github.com/apple1day/mywatch/blob/3c6eaec129e24c0a4a696f27f493ae1753a1ca89/docs/APK_ANALYSIS.md) 记录了用户上传的欢太健康 `4.22.11_8c76bdd_250530` 的静态调用链：OnePlus 一代设备分支进入 BRClientDevice，以公开 Android API `createRfcommSocketToServiceRecord` 建立两个 secure RFCOMM 连接。

| 通道 | APK 中的服务 UUID |
| --- | --- |
| 主／命令 | `db764ac8-4b08-7f25-aafe-59d03c27bae3` |
| 数据 | `db764ac8-4b08-7f25-aafe-59d03c27bae4` |

安卓实现先连接主通道，约 1 秒后建立数据通道。以上是静态证据；还没有用户这块实体手表的 SDP 回包与完整业务握手结果。

这些 UUID 是 RFCOMM 服务标识。本 iOS App 不把它们传给 GATT 服务发现并据此声称移植成功。

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
3. 发现的服务、特征和标准值来自设备回包；不发送自定义认证、控制、升级或账号指令。
4. 原厂绑定、通知和健康同步单独标记为未实现。
5. RFCOMM 状态记为普通 iOS 公共 API 无直接对应实现，而非“已连接”或“手表不支持”。

iOS 的 CBPeripheral identifier 不是蓝牙 MAC。本项目仅为内部选择保存 UUID，导出时使用每次会话独立的匿名标识；不会把它描述成“读取 MAC 后脱敏”。

## 需要什么证据才能继续

- 用户实体手表是否存在 iPhone 能发现的 BLE 广播或可访问 GATT 服务。
- 标准及私有服务 UUID、特征属性、实际连接阶段和退出原因。
- 如另有 GATT 业务通路，需要其真实消息协议和回包；如有 MFi 通路，需要对应支持与协议资料。

未发现广播、连接超时、没有标准电量或主动断开，均不足以单独证明设备彻底不兼容。完整的通知或健康同步仍取决于可用传输和设备端协议，不由界面移植或 SDK 升级自动完成。
