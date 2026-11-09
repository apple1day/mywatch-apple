import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum WatchColors {
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.34)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

private struct ReportSnapshot: Identifiable {
    let id: UUID
    let data: Data
    let metadata: ReportExportMetadata

    init(data: Data) {
        let id = UUID()
        self.id = id
        self.data = data
        metadata = ReportExportMetadata(snapshot: data, exportID: id)
    }
}

struct ContentView: View {
    @ObservedObject var monitor: BluetoothMonitor
    @State private var showAllDevices = false
    @State private var showGuide = false
    @State private var reportSnapshot: ReportSnapshot?

    private var visibleDevices: [DiscoveredDevice] {
        Array(monitor.devices.filter { showAllDevices || $0.isCandidate }.prefix(40))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    compatibilityCard
                    connectionCard
                    devicesCard
                    if monitor.selectedDevice != nil { selectedCard }
                    if monitor.selectedDevice != nil { bindingCard }
                    if !monitor.readings.isEmpty { readingsCard }
                    if !monitor.serviceRows.isEmpty { servicesCard }
                    if !monitor.events.isEmpty { eventsCard }
                    Text("只有实体手表回包才能验证设备互通。名称匹配和 GATT 连接都不代表原厂绑定成功。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
            .background(WatchColors.canvas)
            .navigationTitle("Watch Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showGuide = true } label: {
                        Label("使用说明", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("guideButton")
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    reportSnapshot = ReportSnapshot(data: monitor.makeReport())
                } label: {
                    Label("导出诊断报告", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("exportReportButton")
                .frame(maxWidth: 760)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial)
            }
            .sheet(isPresented: $showGuide) { GuideView() }
            .sheet(item: $reportSnapshot) { snapshot in
                ReportView(snapshot: snapshot.data, metadata: snapshot.metadata)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            WatchGlyph()
                .frame(width: 66, height: 80)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("一代手表连接")
                    .font(.title.bold())
                    .accessibilityIdentifier("homeTitle")
                Text("iPhone 连接验证版 · 0.4.2")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("发现设备，记录真实的连接结果。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var compatibilityCard: some View {
        WatchCard {
            Label("先了解 iOS 的连接范围", systemImage: "info.circle.fill")
                .font(.headline)
            Text("先验证手表身份，再点击“继续首次设置”，向手表发送设置请求并观察实际回应。账号登录、云绑定和健康同步尚未接入，是否能继续设置需要由手表验证。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("compatibilityNotice")
            HStack(spacing: 8) {
                StatusTag(text: "首次设置验证", symbol: "wave.3.right", highlighted: true)
                StatusTag(text: "账号绑定未接入", symbol: "lock")
            }
        }
    }

    private var connectionCard: some View {
        WatchCard {
            HStack {
                Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if monitor.isScanning || monitor.isConnecting || monitor.isCheckingVendorProtocol || monitor.isSettingUp { ProgressView() }
            }
            Text(monitor.stateText)
                .font(.body.weight(.medium))
                .accessibilityIdentifier("connectionState")
            Text(monitor.bluetoothText)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                if monitor.isScanning { monitor.stopScan() }
                else { monitor.startScan() }
            } label: {
                Label(monitor.isScanning ? "停止扫描" : "扫描附近 BLE 设备",
                      systemImage: monitor.isScanning ? "stop.circle" : "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(monitor.isConnecting || monitor.isConnected)
            .accessibilityIdentifier("scanButton")
            Text("扫描约 15 秒后结束。首次扫描会请求蓝牙权限；扫描不到设备时，可查看其他设备或导出报告。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var devicesCard: some View {
        WatchCard {
            HStack {
                Text("发现的设备").font(.headline)
                Spacer()
                Text("\(monitor.devices.count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Toggle("显示其他设备", isOn: $showAllDevices)
                .font(.subheadline)
                .accessibilityIdentifier("showAllDevicesToggle")
            if visibleDevices.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    Text(monitor.isScanning ? "正在寻找附近设备…" : "尚无匹配设备")
                        .font(.subheadline.weight(.medium))
                    Text("让手表亮屏并靠近手机。仅有经典蓝牙广播的设备，可能不会出现在这个列表里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                ForEach(visibleDevices) { device in
                    Button { monitor.selectDevice(device.id) } label: {
                        DeviceRow(device: device, isSelected: device.id == monitor.selectedDeviceID)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(device.name)，\(device.isCandidate ? "名称候选" : "其他设备")")
                    .accessibilityAddTraits(device.id == monitor.selectedDeviceID ? .isSelected : [])
                }
                Text("名称只用于筛选候选，不是型号认证。最多展示 40 条结果。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selectedCard: some View {
        WatchCard {
            Label("已选择的设备", systemImage: "applewatch")
                .font(.headline)
            Text(monitor.selectedDevice?.name ?? "未选择设备")
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            if let failure = monitor.gattFailure {
                GATTFailureNotice(failure: failure) { monitor.startScan() }
            }
            if monitor.isConnected {
                Text("蓝牙通道已连接 · 账号绑定未接入")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if monitor.isConnected || monitor.isConnecting {
                Button(monitor.isConnecting ? "取消连接" : "断开 GATT", role: .destructive) {
                    monitor.disconnect()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("disconnectButton")
            } else {
                Button { monitor.connectSelected() } label: {
                    Label("连接 GATT 并读取标准信息", systemImage: "link")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!monitor.canConnect)
                .accessibilityIdentifier("connectButton")
            }
            Text("选中设备后，先连接并验证身份，再继续首次设置。请保持应用在前台；进入后台会释放连接，重试需重新连接和验证身份。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var bindingCard: some View {
        WatchCard {
            Label("连接验证进度", systemImage: "list.bullet")
                .font(.headline)
            verificationRow("蓝牙通道", state: gattProgressLabel,
                            complete: monitor.isConnected)
            verificationRow("协议能力", state: monitor.vendorProtocol.capabilityProgressLabel,
                            complete: observedCapabilities != nil)
            verificationRow("传输身份", state: authenticationLabel,
                            complete: monitor.vendorProtocol.authentication.transportAuthenticated)
            verificationRow("首次设置", state: initialSetupLabel,
                            complete: monitor.vendorProtocol.initialSetup.deviceSetupFinishedReported)
            verificationRow("账号绑定", state: "尚未接入", complete: false)
            Divider()
            Text(monitor.vendorProtocol.summary)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("vendorProtocolState")
            Text("系统验证码由 iOS 处理。身份验证通过后，本次连接会保留，用于继续首次设置。手表设置状态和账号绑定分别记录。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button { monitor.checkVendorProtocol() } label: {
                HStack {
                    if monitor.isCheckingVendorProtocol { ProgressView() }
                    Text(monitor.vendorCheckButtonTitle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!monitor.canCheckVendorProtocol)
            .accessibilityIdentifier("checkVendorProtocolButton")
            initialSetupActions
            if let capabilities = observedCapabilities {
                Text("手表协议版本：\(capabilities.protocolVersion)")
                    .font(.subheadline)
                if monitor.vendorProtocol.authentication.capabilitySource == "PRE_QUERY_OBSERVATION" {
                    Text("身份流程使用手表主动宣告的完整能力；本次查询是否收到应答在报告中单独记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if monitor.vendorProtocol.status != "NOT_ATTEMPTED" {
                Text("收到手表消息：命令 \(monitor.vendorProtocol.commandNotificationCount) 条 · 文件 \(monitor.vendorProtocol.fileNotificationCount) 条")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("vendorNotificationCounts")
                Text("能力查询：已提交 \(monitor.vendorProtocol.capabilityQuery.submittedAttempts)/\(monitor.vendorProtocol.capabilityQuery.maximumAttempts) 次 · 已确认 \(monitor.vendorProtocol.capabilityQuery.acknowledgedAttempts) 次")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("capabilityQueryCounts")
            }
            if let last = monitor.vendorProtocol.commandWrites.last {
                Text("当前命令写入：\(last.acknowledgedFragments)/\(last.frameCount) 个分片已确认")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let failure = monitor.vendorProtocol.error {
                Text(failure.message)
                    .font(.footnote).foregroundStyle(.red)
                    .accessibilityIdentifier("verificationFailure")
            }
            if !monitor.isCheckingVendorProtocol, !monitor.isSettingUp,
               monitor.vendorProtocol.status != "NOT_ATTEMPTED" {
                Button("导出本次验证结果") {
                    reportSnapshot = ReportSnapshot(data: monitor.makeReport())
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("exportVerificationReportButton")
                Text(monitor.canStartInitialSetup
                     ? "身份验证已通过。请保持前台，点击“继续首次设置”。"
                     : "本轮验证已结束。重新尝试前请先断开并重连。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var initialSetupActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { monitor.startInitialSetup() } label: {
                HStack {
                    if monitor.isSettingUp { ProgressView() }
                    Text(monitor.initialSetupButtonTitle)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!monitor.canStartInitialSetup)
            .accessibilityIdentifier("startInitialSetupButton")
            if monitor.vendorProtocol.initialSetup.status != "NOT_STARTED" {
                Text(monitor.vendorProtocol.initialSetup.summary)
                    .font(.footnote.weight(.medium))
                    .accessibilityIdentifier("initialSetupState")
            }
            Text("继续后会发送开始设置请求，并查询手表状态；查询后的观察最多约 45 秒。请同时查看手表是否离开配对页面。写入确认只表示消息已送达蓝牙层。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var initialSetupLabel: String {
        switch monitor.vendorProtocol.initialSetup.status {
        case "START_SETTING": return "正在开始"
        case "QUERY_OOBE_STATE", "OBSERVING_DEVICE_STATE": return "正在观察"
        case "DEVICE_SETUP_FINISHED_REPORTED": return "设备报告完成"
        case "DEVICE_SETUP_PENDING": return "仍待完成"
        case "DEVICE_STATE_UNRECOGNIZED": return "状态待分析"
        case "FAILED": return "本轮未完成"
        case "INTERRUPTED": return "已中断"
        default: return monitor.canStartInitialSetup ? "可以继续" : "尚未开始"
        }
    }

    private var gattProgressLabel: String {
        if monitor.isConnected { return "已连接" }
        if monitor.isConnecting { return "正在连接" }
        if monitor.gattFailure?.requiresPairingRecovery == true { return "需要重新配对" }
        if monitor.gattFailure?.stage == .disconnection { return "已断开" }
        if monitor.gattFailure != nil { return "连接未完成" }
        return "尚未连接"
    }

    private var observedCapabilities: OppoTransportCapabilities? {
        monitor.vendorProtocol.capabilities ?? monitor.vendorProtocol.authentication.selectedCapabilities
            ?? monitor.vendorProtocol.decoderDiagnostics.unsolicitedCapabilities
    }

    private var authenticationLabel: String {
        switch monitor.vendorProtocol.vendorAuthentication {
        case "PASSED": return "已通过"
        case "IN_PROGRESS": return "正在验证"
        case "FAILED": return "未通过"
        case "INTERRUPTED": return "已中断"
        default: return "尚未开始"
        }
    }

    private func verificationRow(_ title: String, state: String, complete: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: complete ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(complete ? WatchColors.accent : Color.secondary)
                .accessibilityHidden(true)
            Text(title)
            Spacer(minLength: 8)
            Text(state).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }

    private var readingsCard: some View {
        WatchCard {
            Label("设备返回的标准信息", systemImage: "list.bullet.rectangle")
                .font(.headline)
            ForEach(monitor.readings) { reading in
                HStack(alignment: .top, spacing: 16) {
                    Text(reading.label).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(reading.value)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                .font(.subheadline)
                .padding(.vertical, 2)
            }
        }
    }

    private var servicesCard: some View {
        WatchCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(monitor.serviceRows.prefix(60))) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.characteristicUUID ?? row.serviceUUID)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Text(row.characteristicUUID == nil ? "GATT 服务" : row.properties.joined(separator: " · "))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.leading, row.characteristicUUID == nil ? 0 : 12)
                    }
                    if monitor.serviceRows.count > 60 {
                        Text("其余条目请查看诊断报告。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("服务与特征 · \(monitor.serviceRows.count)", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
            }
        }
    }

    private var eventsCard: some View {
        WatchCard {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(monitor.events.suffix(20).reversed())) { event in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.timestamp, style: .time)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Text(event.message).font(.footnote)
                        }
                    }
                }
                .padding(.top, 12)
            } label: {
                Label("连接记录", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
            }
        }
    }
}

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? WatchColors.accent : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 5) {
                Text(device.name).font(.body.weight(.medium)).lineLimit(2)
                Text(device.isCandidate ? "一代名称候选" : "其他附近设备")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if let rssi = device.rssi {
                Text("\(rssi) dBm")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(isSelected ? WatchColors.accent.opacity(0.10) : WatchColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .contentShape(Rectangle())
    }
}

private struct WatchCard<Content: View>: View {
    private let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WatchColors.card)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct StatusTag: View {
    let text: String
    let symbol: String
    var highlighted = false
    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(highlighted ? WatchColors.accent.opacity(0.10) : WatchColors.canvas)
            .clipShape(Capsule())
    }
}

private struct WatchGlyph: View {
    var body: some View {
        ZStack {
            Capsule().fill(WatchColors.accent.opacity(0.24)).frame(width: 27, height: 76)
            RoundedRectangle(cornerRadius: 20).fill(WatchColors.accent).frame(width: 58, height: 58)
            Circle().stroke(.white.opacity(0.45), lineWidth: 1.5).frame(width: 40, height: 40)
            Image(systemName: "wave.3.right").font(.title3.weight(.medium)).foregroundStyle(.white)
        }
    }
}

private struct PairingRecoverySteps: View {
    var body: some View {
        ForEach(Array(GATTConnectionFailure.pairingRecoverySteps.enumerated()), id: \.offset) { index, step in
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1).")
                Text(step).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct GATTFailureNotice: View {
    let failure: GATTConnectionFailure
    let rescan: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(failure.title, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
                .accessibilityIdentifier("gattFailureTitle")
            Text(failure.message)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            if failure.requiresPairingRecovery {
                PairingRecoverySteps().font(.footnote)
                Text("完成系统操作后再点下方重新扫描。App 无法确认系统中的旧配对是否已移除。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let domain = failure.domain, let code = failure.code {
                Text("\(domain) · 错误码 \(code)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Button("重新扫描手表", action: rescan)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("gattRecoveryScanButton")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("gattFailureNotice")
    }
}

private struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("连接失败：配对信息已移除") {
                    Text("如果报告为 CBErrorDomain、错误码 14，表示系统报告手表端已移除配对信息。请按以下步骤重新建立系统配对。")
                        .accessibilityIdentifier("pairingRecoveryGuide")
                    PairingRecoverySteps()
                    Text("当前 App 的连接方式不能直接清除系统配对记录。若系统蓝牙列表没有这只手表或没有 ⓘ，请保留诊断报告，并核对系统蓝牙页面中的设备记录。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("先完成一次连接检查") {
                    Text("1. 让手表亮屏，靠近手机，保留现有绑定和数据。")
                    Text("2. 点击扫描，允许蓝牙权限。没有候选时，打开“显示其他设备”。")
                    Text("3. 选中设备，点击“连接 GATT 并读取标准信息”。")
                    Text("4. 在“连接验证进度”中点击“验证连接与身份”，完成可能出现的系统配对提示。")
                    Text("5. 身份验证通过后，点击“继续首次设置”。保持前台，等待手表状态或明确错误，并观察手表是否离开配对页面。")
                    Text("6. 观察结束后导出 JSON。报告中的首次设置结果、账号绑定状态和写入回执分别记录；设备报告设置完成仍不证明云账号已绑定。")
                }
                Section("手机已确认，手表仍等待") {
                    Text("系统蓝牙配对、手表协议认证和业务绑定是不同阶段。标准信息能读取，不能证明后两步已完成，也不能直接证明系统已经持久保存配对。")
                    Text("0.4.2 保留协议版本 3–5 的身份验证，并使用本次协商结果继续首次设置。版本 1–2 的旧密钥路径仍未适配。")
                    Text("能力查询最多发送 4 次；未取得有效能力时，首片提交 2 秒后、且上一条已完整写入确认，才会重试。收到有效能力后停止新增重试；整个能力等待窗口最多 45 秒。消息计数为 0 时也会显示。")
                    Text("首次设置会发送开始设置请求并查询状态。本版尚未实现原厂账号登录、云绑定及完整同步；若手表仍等待，需要结合最新报告判断它停在哪个业务阶段。")
                    Text("系统配对提示不一定每次连接都出现。应根据命令通知、写入回执和协议结果判断当前进展；手表没有再次显示六位码，不能单独判断蓝牙是否连接。")
                }
                Section("为什么和安卓不同") {
                    Text("安卓验证版能够尝试一代的自定义 RFCOMM 双通道，普通 iOS App 没有直接对应的公共接口。实表报告已确认另一组 BLE 命令特征存在，本版据此尝试能力查询及传输身份认证。")
                    Text("CoreBluetooth 对经典蓝牙的支持是 GATT over BR/EDR，不等于开放任意串口通道。当前也没有这块国行一代提供可用 MFi 协议的证据。")
                    Text("未发现广播、没有标准电量、GATT 连接失败，都不能单独证明手表不兼容。服务存在也不代表该固件支持完整的 BLE 业务绑定，仍需实际回包。")
                }
                Section("报告和隐私") {
                    Text("报告包含所选设备名称、会话匿名标识、系统版本、服务 UUID、传输能力、身份校验结果、首次设置状态码和逐命令写入计数。不保存原始广播载荷、完整外设标识、验证码、密钥、IV 或原始私有载荷。iOS 不向本应用提供蓝牙 MAC 地址。")
                    Text("报告只在你导出时保存到指定位置。本应用不包含账号、分析 SDK 或网络上传功能。")
                    Text("进入后台会结束扫描并释放连接；返回后请手动重试。导出按钮先生成快照，再打开保存界面。")
                }
                Section("系统与项目") {
                    Button("打开本应用的系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                    Link("查看 iOS 项目说明", destination: URL(string: "https://github.com/apple1day/mywatch-apple")!)
                    Link("查看 Android 项目", destination: URL(string: "https://github.com/apple1day/mywatch")!)
                }
            }
            .navigationTitle("使用说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct JSONReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct ReportView: View {
    let snapshot: Data
    let metadata: ReportExportMetadata
    @Environment(\.dismiss) private var dismiss
    @State private var isExporting = false
    @State private var showJSON = false
    @State private var exportStatus: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("已截取当前诊断结果", systemImage: "doc.text")
                        .font(.headline)
                    Text(metadata.versionSummary)
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("reportVersionMetadata")
                    Text(metadata.generatedAtSummary)
                        .font(.footnote.monospacedDigit())
                        .accessibilityIdentifier("reportGeneratedAtMetadata")
                    Text("报告会保留点击导出时的状态。GATT 连接和原厂业务绑定在报告中分别标注。")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text("包含所选设备名称、系统版本及服务信息；发送前可展开下方内容查看。")
                        .font(.footnote).foregroundStyle(.secondary)
                    Button { isExporting = true } label: {
                        Label("保存 JSON", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("saveJSONButton")
                    if let status = exportStatus { Text(status).font(.footnote) }
                }
                Section {
                    Button { showJSON.toggle() } label: {
                        HStack {
                            Text(showJSON ? "收起报告内容" : "查看报告内容")
                            Spacer()
                            Image(systemName: showJSON ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("reportDisclosure")
                    .accessibilityValue(showJSON ? "已展开" : "已折叠")
                    if showJSON {
                        ReportJSONPreview(text: String(data: snapshot, encoding: .utf8) ?? "报告编码不可用")
                            .frame(height: 360)
                    }
                }
            }
            .navigationTitle("诊断报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $isExporting,
                          document: JSONReportDocument(data: snapshot),
                          contentType: .json,
                          defaultFilename: metadata.suggestedFilename) { result in
                switch result {
                case .success: exportStatus = "报告已保存。"
                case .failure: exportStatus = "报告未保存，可重新选择保存位置。"
                }
            }
        }
    }

}

/// Keep the list row bounded while UIKit handles scrolling and selection of the
/// complete report. Accessibility reads the text view's actual text value.
private struct ReportJSONPreview: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        view.isScrollEnabled = true
        view.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(
            for: UIFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.accessibilityIdentifier = "reportJSONPreview"
        view.accessibilityLabel = "诊断报告 JSON"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // Avoid resetting the user's selection and scroll position on redraw.
        if view.text != text { view.text = text }
    }
}
