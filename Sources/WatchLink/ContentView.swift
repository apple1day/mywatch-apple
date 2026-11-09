import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum WatchColors {
    static let accent = Color(red: 0.12, green: 0.43, blue: 0.34)
    static let canvas = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

private struct ReportSnapshot: Identifiable {
    let id = UUID()
    let data: Data
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
            .sheet(item: $reportSnapshot) { snapshot in ReportView(snapshot: snapshot.data) }
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
                Text("iPhone 连接验证版 · 0.2.0")
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
            Text("本版可检查蓝牙连接与手表的协议回应。手机确认验证码后，手表仍可能等待应用完成身份认证和绑定；当前尚未实现这两个后续步骤。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("compatibilityNotice")
            HStack(spacing: 8) {
                StatusTag(text: "BLE 协议检查", symbol: "wave.3.right", highlighted: true)
                StatusTag(text: "业务绑定未适配", symbol: "lock")
            }
        }
    }

    private var connectionCard: some View {
        WatchCard {
            HStack {
                Label("连接状态", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if monitor.isScanning || monitor.isConnecting || monitor.isCheckingVendorProtocol { ProgressView() }
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
            Label("当前设备", systemImage: "checkmark.circle")
                .font(.headline)
            Text(monitor.selectedDevice?.name ?? "未选择设备")
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
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
            Text("连接后先读取标准设备信息，再可检查手表的协议回应。进入后台会释放连接。健康同步、通知、表盘和原厂绑定尚未实现。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var bindingCard: some View {
        WatchCard {
            Label("配对与绑定", systemImage: "lock.open")
                .font(.headline)
            Text(monitor.vendorProtocol.summary)
                .font(.subheadline.weight(.medium))
                .accessibilityIdentifier("vendorProtocolState")
            Text("系统验证码由 iOS 处理，App 无法直接读取系统配对是否完成。手表停在确认页面时，可检查它是否回应后续协议查询。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button { monitor.checkVendorProtocol() } label: {
                Label(monitor.isCheckingVendorProtocol ? "正在检查手表协议…" : "检查手表协议",
                      systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!monitor.canCheckVendorProtocol)
            .accessibilityIdentifier("checkVendorProtocolButton")
            if let capabilities = monitor.vendorProtocol.capabilities {
                Text("手表返回的协议版本：\(capabilities.protocolVersion)")
                    .font(.subheadline)
                Text("已记录协议能力，下一步仍需按手表回应实现身份认证和绑定。请导出本次报告。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let failure = monitor.vendorProtocol.error {
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text(monitor.vendorProtocol.status == "NOT_ATTEMPTED"
                 ? "这一步只查询传输能力，不代表绑定完成。出现系统配对提示时，请核对两端数字并完成确认。"
                 : "每次连接只检查一次。可随时断开；重新检查前请先断开并重连，之后导出 JSON。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
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

private struct GuideView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                Section("先完成一次连接检查") {
                    Text("1. 让手表亮屏，靠近手机，保留现有绑定和数据。")
                    Text("2. 点击扫描，允许蓝牙权限。没有候选时，打开“显示其他设备”。")
                    Text("3. 选中设备，点击“连接 GATT 并读取标准信息”。")
                    Text("4. 在“配对与绑定”中点击“检查手表协议”，完成可能出现的系统配对提示。")
                    Text("5. 等待协议回应或错误，再导出 JSON 报告。协议回应不代表业务绑定成功。")
                }
                Section("手机已确认，手表仍等待") {
                    Text("系统蓝牙配对、手表协议认证和业务绑定是不同阶段。标准信息能读取，不能证明后两步已完成，也不能直接证明系统已经持久保存配对。")
                    Text("0.2.0 新增已核实通道的通知订阅和一次传输能力查询。只保存解析后的能力和失败阶段，后续身份认证与绑定尚未实现。")
                }
                Section("为什么和安卓不同") {
                    Text("安卓验证版能够尝试一代的自定义 RFCOMM 双通道，普通 iOS App 没有直接对应的公共接口。实表报告已确认另一组 BLE 命令特征存在，本版据此增加了协议能力检查。")
                    Text("CoreBluetooth 对经典蓝牙的支持是 GATT over BR/EDR，不等于开放任意串口通道。当前也没有这块国行一代提供可用 MFi 协议的证据。")
                    Text("未发现广播、没有标准电量、GATT 连接失败，都不能单独证明手表不兼容。服务存在也不代表该固件支持完整的 BLE 业务绑定，仍需实际回包。")
                }
                Section("报告和隐私") {
                    Text("报告包含所选设备名称、会话匿名标识、系统版本、服务 UUID、传输能力和连接记录。不保存原始广播载荷、完整外设标识、验证码、密钥或原始私有载荷。iOS 不向本应用提供蓝牙 MAC 地址。")
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
                        Text(String(data: snapshot, encoding: .utf8) ?? "报告编码不可用")
                            .font(.caption.monospaced())
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("reportJSONPreview")
                    }
                }
            }
            .navigationTitle("诊断报告")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .fileExporter(isPresented: $isExporting,
                          document: JSONReportDocument(data: snapshot),
                          contentType: .json,
                          defaultFilename: "WatchLink-iOS-\(Self.filenameDate())") { result in
                switch result {
                case .success: exportStatus = "报告已保存。"
                case .failure: exportStatus = "报告未保存，可重新选择保存位置。"
                }
            }
        }
    }

    private static func filenameDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
