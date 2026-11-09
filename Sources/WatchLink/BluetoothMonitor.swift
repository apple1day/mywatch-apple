import Foundation
import CoreBluetooth
import Combine
import UIKit

/// Each connection has its own delegate token, so retired work cannot change the new report.
private final class PeripheralDelegate: NSObject, CBPeripheralDelegate {
    weak var owner: BluetoothMonitor?
    let token: Int

    init(owner: BluetoothMonitor, token: Int) {
        self.owner = owner
        self.token = token
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        owner?.receivedServices(peripheral, error: error, token: token)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        owner?.receivedCharacteristics(peripheral, service: service, error: error, token: token)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.receivedValue(peripheral, characteristic: characteristic, error: error, token: token)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        owner?.receivedNotificationState(peripheral, characteristic: characteristic, error: error, token: token)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        owner?.receivedWriteAcknowledgement(peripheral, characteristic: characteristic, error: error, token: token)
    }
}

/// Foreground-only Core Bluetooth diagnostic controller. All delegates use the main queue.
final class BluetoothMonitor: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var stateText = "等待开始检测"
    @Published private(set) var bluetoothText = "尚未请求蓝牙权限"
    // These UI operation flags include the cancellable Bluetooth preparation phase.
    @Published private(set) var isScanning = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isConnected = false
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var selectedDeviceID: UUID?
    @Published private(set) var serviceRows: [ServiceRow] = []
    @Published private(set) var readings: [StandardReading] = []
    @Published private(set) var events: [ProbeEvent] = []
    @Published private(set) var isCheckingVendorProtocol = false
    @Published private(set) var vendorProtocol = VendorProbeSnapshot()

    private enum PendingAction { case scan, connect(UUID) }
    private enum Phase { case idle, waiting, scanning, connecting, services, characteristics, reading, ready, vendor }
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var peripheralDelegate: PeripheralDelegate?
    private var pendingAction: PendingAction?
    private var phase: Phase = .idle
    private var generation = 0
    private var timer: DispatchWorkItem?
    private var timerRevision = 0
    private var pendingServices: [CBService] = []
    private var expectedService: CBService?
    private var pendingReads: [CBCharacteristic] = []
    private var expectedRead: CBCharacteristic?
    private var queuedReadUUIDs: Set<String> = []
    private var gattObserved = false
    private var result = "NOT_ATTEMPTED"
    private let sessionSalt = UUID().uuidString
    private var deviceLimitReported = false
    private var vendorCharacteristics: [CBCharacteristic] = []
    private var vendorTransport: VendorGATTTransport?
    private var vendorDecoder = OppoTransportDecoder(emitAuthenticationMessages: true)
    private var authentication: OppoAuthentication?
    private var activeVendorWriteIndex: Int?
    private var activeAuthenticationToken: Int?

    var selectedDevice: DiscoveredDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var canConnect: Bool {
        guard let selectedDevice else { return false }
        return !isScanning && !isConnecting && !isConnected
            && selectedDevice.isConnectable != false
    }

    var canExportReport: Bool { selectedDeviceID != nil || !events.isEmpty }

    var canCheckVendorProtocol: Bool {
        isConnected && phase == .ready && vendorProtocol.profileAvailable
            && vendorProtocol.status == "NOT_ATTEMPTED"
    }

    var vendorCheckButtonTitle: String {
        if vendorProtocol.status != "NOT_ATTEMPTED" { return vendorProtocol.checkButtonTitle }
        if !isConnected { return "请先连接蓝牙" }
        if phase != .ready { return "正在读取设备信息…" }
        if !vendorProtocol.profileAvailable { return "未发现完整协议通道" }
        return "验证连接与身份"
    }

    /// One complete verification session per GATT connection. All subsequent
    /// identity commands are serialized behind real ATT completion callbacks.
    func checkVendorProtocol() {
        guard canCheckVendorProtocol, let peripheral,
              let write = vendorCharacteristic(service: OppoGATTProfile.commandService,
                                                uuid: OppoGATTProfile.commandWrite),
              let notify = vendorCharacteristic(service: OppoGATTProfile.commandService,
                                                 uuid: OppoGATTProfile.commandNotify) else { return }
        let fileNotify = vendorCharacteristic(service: OppoGATTProfile.fileService,
                                               uuid: OppoGATTProfile.fileNotify)
        let token = generation
        vendorDecoder.reset()
        authentication?.cancel()
        authentication = nil
        activeVendorWriteIndex = nil
        activeAuthenticationToken = nil
        vendorProtocol.status = "SUBSCRIBING"
        vendorProtocol.startedAt = Date()
        isCheckingVendorProtocol = true
        phase = .vendor
        result = "VENDOR_PROTOCOL_SUBSCRIBING"
        stateText = vendorProtocol.summary
        addEvent("开始连接与身份验证：先检查协议能力，再按手表实际版本验证本地身份。业务绑定和首次设置尚未实现。")

        let transport = VendorGATTTransport(
            peripheral: peripheral, commandWrite: write, commandNotify: notify, fileNotify: fileNotify,
            onReady: { [weak self] in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.recordVendorNotifications()
                self.beginVendorQuery()
            },
            onReceived: { [weak self] channel, data in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.receiveVendorData(channel, data: data)
            },
            onFragmentSubmitted: { [weak self] index in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.vendorFragmentSubmitted(index)
            },
            onWriteComplete: { [weak self] in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.vendorWriteCompleted()
            },
            onFailure: { [weak self] error in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.vendorTransportFailed(error)
            }
        )
        vendorTransport = transport
        transport.start()
    }

    private func beginVendorQuery() {
        guard let transport = vendorTransport, transport.isReady else { return }
        vendorProtocol.commandWrites.append(.init(commandID: 1, stage: "TRANSPORT_QUERY",
                                                  frameCount: 1, queuedAt: Date()))
        activeVendorWriteIndex = vendorProtocol.commandWrites.count - 1
        activeAuthenticationToken = nil
        if !transport.send(fragments: [OppoProtocol.transportConsultRequest], intervalMilliseconds: 10), isCheckingVendorProtocol {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1002, message: "能力查询没有进入发送队列。"))
        }
    }

    private func vendorFragmentSubmitted(_ fragmentIndex: Int) {
        guard let index = activeVendorWriteIndex, vendorProtocol.commandWrites.indices.contains(index),
              vendorProtocol.commandWrites[index].recordSubmission(index: fragmentIndex, at: Date()) else {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1006, message: "发送分片与当前命令记录不一致。"))
            return
        }
        guard fragmentIndex == 0 else { return }
        if let token = activeAuthenticationToken, let authentication {
            setTimer(seconds: 45) { [weak self] in
                guard let self, self.isCheckingVendorProtocol, let authentication = self.authentication else { return }
                self.handleAuthenticationActions(authentication.timeout())
            }
            handleAuthenticationActions(authentication.didSubmit(
                token: token, streamOffset: vendorDecoder.diagnostics.receivedByteCount))
        } else {
            vendorDecoder.markQuerySubmitted()
            vendorProtocol.requestSubmitted = true
            vendorProtocol.querySubmittedAt = Date()
            vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
            vendorProtocol.status = "WAITING_FOR_RESPONSE"
            result = "VENDOR_PROTOCOL_WAITING_FOR_RESPONSE"
            stateText = vendorProtocol.summary
            addEvent("已提交传输能力查询。取得完整能力并确认写入后，才会选择相应的身份流程。")
            setTimer(seconds: 45) { [weak self] in
                guard let self, self.isCheckingVendorProtocol, self.authentication == nil else { return }
                let detail = self.vendorDecoder.diagnostics.lastIssue.map { " 最近接收情况：\($0)。" } ?? ""
                self.vendorProbeFailed(.init(phase: "PROTOCOL_RESPONSE", domain: "WatchLink.ProtocolProbe",
                                             code: 1001, message: self.vendorDecoder.hasPendingData
                                                ? "等待能力信息超时，仍有未完成的消息。\(detail)"
                                                : "未取得可用于身份认证的完整能力信息。\(detail)"))
            }
        }
    }

    private func vendorWriteCompleted() {
        guard let index = activeVendorWriteIndex, vendorProtocol.commandWrites.indices.contains(index),
              vendorProtocol.commandWrites[index].fullyAcknowledged else {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1006, message: "命令完成回调与逐片写入记录不一致。"))
            return
        }
        let token = activeAuthenticationToken
        let commandID = vendorProtocol.commandWrites[index].commandID
        activeVendorWriteIndex = nil
        activeAuthenticationToken = nil
        if let token, let authentication {
            addEvent("身份流程命令 \(commandID) 的全部分片已收到 ATT 确认；设备协议校验单独判断。")
            handleAuthenticationActions(authentication.writeCompleted(token: token, succeeded: true))
        } else {
            beginAuthenticationIfReady()
        }
    }

    private func beginAuthenticationIfReady() {
        guard isCheckingVendorProtocol, authentication == nil,
              vendorProtocol.attWriteAcknowledged, activeVendorWriteIndex == nil,
              let transport = vendorTransport, transport.isReady, !transport.isWriting else { return }
        let choice: VendorCapabilitySelection.Choice
        do {
            guard let observed = try VendorCapabilitySelection.choose(
                response: vendorProtocol.capabilities,
                unsolicited: vendorDecoder.diagnostics.unsolicitedCapabilities) else { return }
            choice = observed
        } catch {
            vendorProbeFailed(.init(phase: "CAPABILITY_VALIDATION", domain: "WatchLink.ProtocolProbe",
                                    code: 2006, message: "查询前后的能力参数不一致，已停止选择身份流程。"))
            return
        }
        let selected = choice.capabilities
        let source = choice.source
        cancelTimer()
        vendorProtocol.authentication.selectedCapabilities = selected
        vendorProtocol.authentication.capabilitySource = source
        vendorProtocol.authentication.startedAt = Date()
        vendorProtocol.authentication.status = "IN_PROGRESS"
        vendorProtocol.vendorAuthentication = "IN_PROGRESS"
        vendorProtocol.status = "AUTHENTICATING"
        result = "VENDOR_AUTHENTICATING"
        let engine = OppoAuthentication()
        authentication = engine
        addEvent("根据完整能力消息选择身份流程：协议版本 \(selected.protocolVersion)，来源 \(source)。前置主动能力不标为本次查询应答。")
        handleAuthenticationActions(engine.start(capabilities: selected))
    }

    private func syncAuthenticationObservations() {
        guard let authentication else { return }
        vendorProtocol.authentication.phase = authentication.phase
        vendorProtocol.authentication.diagnostics = authentication.diagnostics
        vendorProtocol.authentication.identityVerified = authentication.identityVerified
        vendorProtocol.authentication.keyExchangeVerified = authentication.keyExchangeVerified
    }

    private func handleAuthenticationActions(_ actions: [OppoAuthentication.Action],
                                             transportFailure: VendorGATTTransport.Failure? = nil) {
        syncAuthenticationObservations()
        if isCheckingVendorProtocol { stateText = vendorProtocol.summary }
        for action in actions {
            guard isCheckingVendorProtocol else { return }
            switch action {
            case .send(let command):
                sendAuthenticationCommand(command)
            case .completed(let completion):
                syncAuthenticationObservations()
                vendorProtocol.authentication.status = "PASSED"
                vendorProtocol.authentication.transportAuthenticated = true
                vendorProtocol.authentication.completedAt = Date()
                vendorProtocol.vendorAuthentication = "PASSED"
                vendorProtocol.status = "AUTHENTICATED_BINDING_PENDING"
                result = "TRANSPORT_AUTHENTICATED_BINDING_PENDING"
                stateText = vendorProtocol.summary
                isCheckingVendorProtocol = false
                phase = .ready
                cancelTimer()
                recordVendorNotifications()
                vendorTransport?.cancel()
                authentication = nil
                addEvent("已完成协议版本 \(completion.protocolVersion) 的传输身份验证；加密协商\(completion.encryptedTransport ? "已完成" : "未被手表要求")。业务绑定、首次设置和健康同步尚未执行。")
            case .failed(let failure):
                vendorProtocol.authentication.error = failure
                vendorProbeFailed(transportFailure ?? .init(
                    phase: "AUTH_" + failure.phase.rawValue.uppercased(), domain: "WatchLink.Authentication",
                    code: 2001, message: "\(failure.code)：\(failure.message)"))
            }
        }
    }

    private func sendAuthenticationCommand(_ command: OppoAuthentication.Command) {
        guard let transport = vendorTransport, transport.isReady, !transport.isWriting,
              activeVendorWriteIndex == nil,
              let capabilities = vendorProtocol.authentication.selectedCapabilities else {
            vendorProbeFailed(.init(phase: "AUTH_COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 2002, message: "身份命令与当前写入状态不一致。"))
            return
        }
        let frameLimit = min(min(20, capabilities.maxFrameSize),
                             min(capabilities.maxTransmissionUnit, transport.maximumWriteLength))
        guard (0...1000).contains(capabilities.interval) else {
            vendorProbeFailed(.init(phase: "AUTH_TRANSPORT_LIMIT", domain: "WatchLink.ProtocolProbe",
                                    code: 2003, message: "手表要求的发送间隔超过本版支持范围。"))
            return
        }
        do {
            let fragments = try OppoProtocol.encode(service: command.serviceID, command: command.commandID,
                                                     protobuf: command.protobuf, maximumFrameLength: frameLimit)
            guard vendorProtocol.commandWrites.count < 8 else {
                throw OppoDecodeError.oversizedInput
            }
            vendorProtocol.commandWrites.append(.init(commandID: Int(command.commandID), stage: command.phase.rawValue,
                                                      frameCount: fragments.count, queuedAt: Date()))
            activeVendorWriteIndex = vendorProtocol.commandWrites.count - 1
            activeAuthenticationToken = command.token
            addEvent("开始\(vendorProtocol.authentication.phaseDescription)：命令 \(command.commandID)，\(fragments.count) 个分片。")
            if !transport.send(fragments: fragments, intervalMilliseconds: max(10, capabilities.interval)),
               isCheckingVendorProtocol {
                vendorTransportFailed(.init(phase: "AUTH_COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                             code: 2004, message: "身份命令没有进入发送队列。"))
            }
        } catch {
            vendorProbeFailed(.init(phase: "AUTH_FRAME_ENCODING", domain: "WatchLink.ProtocolProbe",
                                    code: 2005, message: "当前帧长、ATT 限额或消息大小无法安全发送身份命令。"))
        }
    }

    private func vendorTransportFailed(_ failure: VendorGATTTransport.Failure) {
        if let authentication, let token = activeAuthenticationToken {
            let actions = authentication.writeCompleted(token: token, succeeded: false)
            handleAuthenticationActions(actions, transportFailure: failure)
            if isCheckingVendorProtocol { vendorProbeFailed(failure) }
        } else {
            vendorProbeFailed(failure)
        }
    }

    func startScan() {
        retireRadio()
        devices = []
        selectedDeviceID = nil
        clearObservations()
        deviceLimitReported = false
        stateText = "正在准备 BLE 扫描"
        addEvent("开始新一轮 BLE 检测。名称匹配只表示候选，不验证手表型号。")
        beginRadio(.scan)
    }

    func stopScan() {
        guard isScanning || (phase == .waiting && selectedDeviceID == nil) else { return }
        retireRadio()
        result = "SCAN_STOPPED"
        stateText = "扫描已停止 · 发现 \(devices.count) 台 BLE 设备"
        addEvent("扫描已停止。扫描不到设备不能证明手表不存在经典蓝牙连接能力。")
    }

    func selectDevice(_ id: UUID) {
        guard let device = devices.first(where: { $0.id == id }) else { return }
        retireRadio()
        selectedDeviceID = id
        clearObservations()
        stateText = "已选择 \(device.name) · 等待 GATT 检测"
        addEvent("已选择设备；后续报告只记录本设备的观测。")
    }

    func connectSelected() {
        guard canConnect, let id = selectedDeviceID else { return }
        retireRadio()
        clearObservations()
        isConnecting = true
        result = "CONNECTING_GATT"
        stateText = "正在准备 GATT 连接"
        addEvent("请求 Core Bluetooth GATT 连接；不尝试一代的 RFCOMM 主／数据通道。")
        beginRadio(.connect(id))
    }

    func disconnect() {
        let hadWork = isConnected || isConnecting || isScanning || pendingAction != nil
        retireRadio()
        if hadWork {
            result = "USER_DISCONNECTED"
            stateText = "连接已释放 · 本次观测已保留"
            addEvent("用户结束本次连接。")
        }
    }

    func pauseForBackground() {
        let hadWork = central != nil
        retireRadio()
        if hadWork {
            result = "PAUSED_FOR_BACKGROUND"
            stateText = "进入后台后已暂停 · 返回可重新检测"
            addEvent("应用进入后台，扫描及 GATT 连接已释放。")
        }
    }

    /// Call before showing the share sheet to preserve the current connection state.
    func makeReport() -> Data {
        let report = ProbeReport(
            schemaVersion: 4,
            generatedAt: Date(),
            platform: PlatformSnapshot(
                system: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                deviceType: UIDevice.current.model,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "4"
            ),
            capabilities: CapabilitySnapshot(),
            selectedDevice: selectedDevice.map { DeviceSnapshot(device: $0, salt: sessionSalt) },
            observations: ObservationSnapshot(
                stateText: stateText, bluetoothState: bluetoothText,
                scanningAtExport: phase == .scanning, connectingAtExport: phase == .connecting,
                gattConnectedAtExport: isConnected,
                gattConnectionObservedThisAttempt: gattObserved, result: result
            ),
            services: serviceRows,
            standardReadings: readings,
            events: events,
            privacy: "设备标识为本次启动加盐摘要；不包含完整 Core Bluetooth 设备 UUID、MAC 地址、原始广播载荷、验证码、密钥或原始私有载荷。仅记录传输能力、身份校验阶段与结果、逐命令写入计数及有界帧头。身份随机值、挑战、加密证明和会话密钥只在内存中处理，不写入报告。查询前能力单独标注来源，不作为查询应答。设备名和标准设备信息仍可能识别你的设备。",
            vendorProtocol: vendorProtocol
        )
        return report.encoded()
    }

    private func beginRadio(_ action: PendingAction) {
        pendingAction = action
        phase = .waiting
        bluetoothText = "正在检查蓝牙状态"
        switch action {
        case .scan:
            isScanning = true
            result = "PREPARING_BLE"
        case .connect:
            isConnecting = true
            result = "PREPARING_GATT"
        }
        setTimer(seconds: 30) { [weak self] in
            guard let self, self.phase == .waiting else { return }
            self.fail("蓝牙准备超时，请完成系统权限提示后重试", result: "BLUETOOTH_PREPARATION_TIMEOUT")
        }
        // A new central instance separates callbacks from every previous scan/connection.
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    private func retireRadio() {
        recordVendorNotifications()
        if isCheckingVendorProtocol {
            _ = vendorDecoder.finish()
            vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
            vendorProtocol.status = "INTERRUPTED"
        }
        if let authentication {
            authentication.cancel()
            syncAuthenticationObservations()
            if !vendorProtocol.authentication.transportAuthenticated {
                vendorProtocol.authentication.status = "INTERRUPTED"
                vendorProtocol.vendorAuthentication = "INTERRUPTED"
            }
        }
        authentication = nil
        activeVendorWriteIndex = nil
        activeAuthenticationToken = nil
        isCheckingVendorProtocol = false
        vendorTransport?.cancel()
        vendorTransport = nil
        vendorDecoder.reset()
        vendorCharacteristics = []
        generation += 1
        cancelTimer()
        pendingAction = nil
        peripheral?.delegate = nil
        let oldCentral = central
        oldCentral?.delegate = nil
        if let oldCentral, oldCentral.state == .poweredOn {
            oldCentral.stopScan()
            if let peripheral { oldCentral.cancelPeripheralConnection(peripheral) }
        }
        central = nil
        peripheral = nil
        peripheralDelegate = nil
        pendingServices = []
        expectedService = nil
        pendingReads = []
        expectedRead = nil
        queuedReadUUIDs = []
        phase = .idle
        isScanning = false
        isConnecting = false
        isConnected = false
    }

    private func clearObservations() {
        serviceRows = []
        readings = []
        events = []
        gattObserved = false
        result = "NOT_ATTEMPTED"
        vendorProtocol = VendorProbeSnapshot()
    }

    private func addEvent(_ text: String) {
        events.append(ProbeEvent(message: text))
        if events.count > 200 { events.removeFirst(events.count - 200) }
    }

    private func setTimer(seconds: TimeInterval, action: @escaping () -> Void) {
        cancelTimer()
        let token = generation
        let revision = timerRevision
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.timerRevision == revision else { return }
            action()
        }
        timer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelTimer() {
        timerRevision += 1
        timer?.cancel()
        timer = nil
    }

    private func fail(_ text: String, result code: String) {
        retireRadio()
        result = code
        stateText = text
        addEvent(text)
    }

    private func errorSuffix(_ error: Error?) -> String {
        guard let error else { return "" }
        let detail = error as NSError
        return "（\(WatchProfile.safeText(detail.domain, limit: 120))，错误码 \(detail.code)）"
    }

    func centralManagerDidUpdateState(_ manager: CBCentralManager) {
        guard manager === central else { return }
        switch manager.state {
        case .poweredOn:
            bluetoothText = "蓝牙已开启"
            guard let action = pendingAction else { return }
            pendingAction = nil
            cancelTimer()
            switch action {
            case .scan:
                phase = .scanning
                isScanning = true
                result = "SCANNING_BLE"
                stateText = "正在扫描 BLE · 15 秒后自动停止"
                manager.scanForPeripherals(withServices: nil,
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
                setTimer(seconds: 15) { [weak self] in self?.stopScan() }
            case .connect(let id):
                guard selectedDeviceID == id,
                      let target = manager.retrievePeripherals(withIdentifiers: [id]).first else {
                    fail("系统暂时无法找回此设备，请重新扫描", result: "PERIPHERAL_NOT_RETRIEVED")
                    return
                }
                peripheral = target
                let delegate = PeripheralDelegate(owner: self, token: generation)
                peripheralDelegate = delegate
                target.delegate = delegate
                phase = .connecting
                isConnecting = true
                stateText = "正在连接 GATT · 等待设备回应"
                manager.connect(target, options: nil)
                setTimer(seconds: 25) { [weak self] in
                    self?.fail("GATT 连接超时，请确认设备正在广播并靠近手机", result: "CONNECT_TIMEOUT")
                }
            }
        case .poweredOff:
            bluetoothText = "蓝牙已关闭"
            fail("请在系统设置中开启蓝牙后重新扫描", result: "BLUETOOTH_POWERED_OFF")
        case .unauthorized:
            bluetoothText = "未获蓝牙权限"
            fail("请允许本应用使用蓝牙，再重新扫描", result: "BLUETOOTH_UNAUTHORIZED")
        case .unsupported:
            bluetoothText = "当前环境不支持蓝牙"
            fail("当前设备或模拟器不支持此蓝牙检测", result: "BLUETOOTH_UNSUPPORTED")
        case .resetting:
            bluetoothText = "蓝牙正在重置"
            if phase != .waiting { fail("蓝牙正在重置，请稍后重新扫描", result: "BLUETOOTH_RESETTING") }
        case .unknown:
            bluetoothText = "正在读取蓝牙状态"
        @unknown default:
            bluetoothText = "蓝牙状态未知"
            fail("系统返回未知蓝牙状态，请稍后重试", result: "BLUETOOTH_UNKNOWN")
        }
    }

    func centralManager(_ manager: CBCentralManager, didDiscover device: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard manager === central, phase == .scanning, isScanning else { return }
        let rawName = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? device.name ?? "未命名 BLE 设备"
        let name = WatchProfile.safeText(rawName)
        let serviceIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            .prefix(32).map { WatchProfile.normalizeUUID($0.uuidString) }
        let discovered = DiscoveredDevice(
            id: device.identifier, name: name.isEmpty ? "未命名 BLE 设备" : name,
            rssi: RSSI.intValue == 127 ? nil : RSSI.intValue,
            isCandidate: WatchProfile.isNameCandidate(rawName),
            advertisedServices: serviceIDs,
            isConnectable: (advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue
        )
        if let index = devices.firstIndex(where: { $0.id == device.identifier }) {
            devices[index] = discovered
        } else if devices.count < 150 {
            devices.append(discovered)
        } else if !deviceLimitReported {
            deviceLimitReported = true
            addEvent("设备列表已达到 150 台上限；可在靠近手表后重新扫描。")
        }
        devices.sort {
            if $0.isCandidate != $1.isCandidate { return $0.isCandidate }
            if $0.rssi != $1.rssi { return ($0.rssi ?? -999) > ($1.rssi ?? -999) }
            if $0.name != $1.name { return $0.name < $1.name }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    func centralManager(_ manager: CBCentralManager, didConnect device: CBPeripheral) {
        guard manager === central, device === peripheral, phase == .connecting else { return }
        cancelTimer()
        isConnecting = false
        isConnected = true
        gattObserved = true
        result = "GATT_CONNECTED_ONLY"
        stateText = "GATT 已连接 · 正在发现服务"
        addEvent("Core Bluetooth GATT 连接已建立。这不表示一代 RFCOMM 通道或原厂绑定成功。")
        phase = .services
        device.discoverServices(nil)
        setTimer(seconds: 20) { [weak self] in
            self?.fail("服务发现超时，连接已释放；本次 GATT 连通记录保留", result: "SERVICES_TIMEOUT")
        }
    }

    func centralManager(_ manager: CBCentralManager, didFailToConnect device: CBPeripheral, error: Error?) {
        guard manager === central, device === peripheral else { return }
        fail("GATT 未能连接\(errorSuffix(error))", result: "GATT_CONNECT_FAILED")
    }

    func centralManager(_ manager: CBCentralManager, didDisconnectPeripheral device: CBPeripheral, error: Error?) {
        guard manager === central, device === peripheral else { return }
        if isCheckingVendorProtocol {
            let detail = error as NSError?
            vendorProtocol.error = .init(phase: "LINK_DISCONNECTED",
                                         domain: detail?.domain ?? "WatchLink.ProtocolProbe",
                                         code: detail?.code ?? 1005,
                                         message: "协议检查期间 GATT 连接断开。")
        }
        fail("GATT 连接已断开\(errorSuffix(error)) · 观测已保留", result: "GATT_DISCONNECTED")
    }

    private func current(_ device: CBPeripheral, token: Int) -> Bool {
        token == generation && device === peripheral && isConnected
    }

    fileprivate func receivedServices(_ device: CBPeripheral, error: Error?, token: Int) {
        guard current(device, token: token), phase == .services else { return }
        cancelTimer()
        guard error == nil else {
            fail("服务发现失败\(errorSuffix(error))", result: "SERVICES_FAILED")
            return
        }
        let services = device.services ?? []
        if services.count > 40 { addEvent("服务数超过 40，诊断只枚举前 40 个。") }
        pendingServices = Array(services.prefix(40))
        for (index, service) in pendingServices.enumerated() {
            serviceRows.append(ServiceRow(id: "service-\(index)",
                                          serviceUUID: WatchProfile.normalizeUUID(service.uuid.uuidString),
                                          characteristicUUID: nil, properties: []))
        }
        discoverNextService()
    }

    private func discoverNextService() {
        guard let peripheral, isConnected else { return }
        guard !pendingServices.isEmpty else { readNextValue(); return }
        let service = pendingServices.removeFirst()
        expectedService = service
        phase = .characteristics
        stateText = "GATT 已连接 · 正在枚举特征"
        peripheral.discoverCharacteristics(nil, for: service)
        setTimer(seconds: 15) { [weak self] in
            self?.fail("特征发现超时，连接已释放", result: "CHARACTERISTICS_TIMEOUT")
        }
    }

    fileprivate func receivedCharacteristics(_ device: CBPeripheral, service: CBService,
                                            error: Error?, token: Int) {
        guard current(device, token: token), phase == .characteristics, service === expectedService else { return }
        cancelTimer()
        expectedService = nil
        if error != nil {
            addEvent("有一个服务无法枚举特征\(errorSuffix(error))；继续其他服务。")
            discoverNextService()
            return
        }
        let characteristics = service.characteristics ?? []
        for characteristic in characteristics {
            if serviceRows.count >= 500 {
                addEvent("服务／特征列表达到 500 行上限，停止继续枚举。")
                pendingServices = []
                break
            }
            let serviceUUID = WatchProfile.normalizeUUID(service.uuid.uuidString)
            let uuid = WatchProfile.normalizeUUID(characteristic.uuid.uuidString)
            serviceRows.append(ServiceRow(id: "characteristic-\(serviceRows.count)", serviceUUID: serviceUUID,
                                          characteristicUUID: uuid, properties: Self.propertyLabels(characteristic.properties)))
            if (serviceUUID == OppoGATTProfile.commandService &&
                [OppoGATTProfile.commandWrite, OppoGATTProfile.commandNotify].contains(uuid)) ||
                (serviceUUID == OppoGATTProfile.fileService && uuid == OppoGATTProfile.fileNotify) {
                vendorCharacteristics.append(characteristic)
            }
            if characteristic.properties.contains(.read),
               WatchProfile.canReadStandard(characteristic: uuid, service: serviceUUID),
               queuedReadUUIDs.insert(uuid).inserted {
                pendingReads.append(characteristic)
            }
        }
        discoverNextService()
    }

    private func readNextValue() {
        guard let peripheral, isConnected else { return }
        guard !pendingReads.isEmpty else {
            phase = .ready
            expectedRead = nil
            cancelTimer()
            vendorProtocol.profileAvailable = OppoGATTProfile.isAvailable(in: serviceRows)
            vendorProtocol.profileDiscoveryCompleted = true
            result = readings.contains(where: { $0.status == "READ_ERROR" })
                ? "GATT_DIAGNOSTICS_PARTIAL" : "GATT_DIAGNOSTICS_COMPLETE"
            stateText = vendorProtocol.profileAvailable
                ? "GATT 检测完成 · 可继续验证连接与身份"
                : "GATT 检测完成 · 未发现完整的手表协议通道"
            addEvent(readings.isEmpty ? "未发现可读取的标准电量／设备信息字段。没有标准字段不能单独证明不兼容。" : "已完成标准字段读取；没有执行私有认证、绑定或控制写入。")
            if vendorProtocol.profileAvailable {
                addEvent("发现已核实 UUID 的命令写入与通知特征。可开始一次能力查询及身份验证；特征存在不代表业务绑定已实现。")
            }
            return
        }
        let characteristic = pendingReads.removeFirst()
        expectedRead = characteristic
        phase = .reading
        let uuid = WatchProfile.normalizeUUID(characteristic.uuid.uuidString)
        stateText = "GATT 已连接 · 正在读取\(WatchProfile.standardLabel(uuid) ?? "标准信息")"
        peripheral.readValue(for: characteristic)
        setTimer(seconds: 10) { [weak self] in
            self?.fail("标准字段读取超时，连接已释放", result: "READ_TIMEOUT")
        }
    }

    fileprivate func receivedValue(_ device: CBPeripheral, characteristic: CBCharacteristic,
                                  error: Error?, token: Int) {
        guard current(device, token: token) else { return }
        vendorTransport?.valueUpdated(device, characteristic: characteristic, error: error)
        guard phase == .reading, characteristic === expectedRead else { return }
        cancelTimer()
        expectedRead = nil
        let uuid = WatchProfile.normalizeUUID(characteristic.uuid.uuidString)
        guard let label = WatchProfile.standardLabel(uuid) else { readNextValue(); return }
        let parsed = error == nil ? WatchProfile.standardValue(uuid: uuid, data: characteristic.value)
            : (value: "读取失败\(errorSuffix(error))", status: "READ_ERROR")
        readings.append(StandardReading(uuid: uuid, label: label, value: parsed.value, status: parsed.status))
        readNextValue()
    }

    fileprivate func receivedNotificationState(_ device: CBPeripheral, characteristic: CBCharacteristic,
                                              error: Error?, token: Int) {
        guard current(device, token: token) else { return }
        vendorTransport?.notificationStateChanged(device, characteristic: characteristic, error: error)
        recordVendorNotifications()
    }

    fileprivate func receivedWriteAcknowledgement(_ device: CBPeripheral, characteristic: CBCharacteristic,
                                                 error: Error?, token: Int) {
        guard current(device, token: token) else { return }
        if let expected = vendorCharacteristic(service: OppoGATTProfile.commandService,
                                               uuid: OppoGATTProfile.commandWrite), characteristic === expected,
           let index = activeVendorWriteIndex, vendorProtocol.commandWrites.indices.contains(index) {
            let failure = error.map { error -> VendorGATTTransport.Failure in
                let detail = error as NSError
                return .init(phase: "COMMAND_WRITE", domain: detail.domain, code: detail.code,
                             message: "ATT 写入回调返回错误：\(detail.localizedDescription)")
            }
            if vendorProtocol.commandWrites[index].recordCallback(error: failure, at: Date()),
               vendorProtocol.commandWrites[index].commandID == 1 {
                if vendorProtocol.recordWriteCompletion(error: failure, at: Date()) {
                    addEvent(failure == nil ? "能力查询的 ATT 写入已确认。" : "能力查询的 ATT 写入返回错误。")
                }
            }
        }
        // Receipt facts above survive local protocol cancellation. Only the live
        // transport can finish a logical command and advance authentication.
        vendorTransport?.writeCompleted(device, characteristic: characteristic, error: error)
    }

    private func vendorCharacteristic(service: String, uuid: String) -> CBCharacteristic? {
        let matches = vendorCharacteristics.filter {
            $0.service.map { WatchProfile.normalizeUUID($0.uuid.uuidString) == service } == true
                && WatchProfile.normalizeUUID($0.uuid.uuidString) == uuid
        }
        return matches.count == 1 ? matches.first : nil
    }

    private func recordVendorNotifications() {
        guard let transport = vendorTransport else { return }
        vendorProtocol.commandNotificationsEnabled = transport.commandNotificationsEnabled
        vendorProtocol.fileNotificationsEnabled = transport.fileNotificationsEnabled
    }

    private func receiveVendorData(_ channel: VendorGATTTransport.Channel, data: Data) {
        guard vendorProtocol.notificationCount < 4096,
              data.count <= 256 * 1024 - vendorProtocol.receivedByteCount else {
            vendorProbeFailed(.init(phase: "PROTOCOL_RECEIVE", domain: "WatchLink.ProtocolProbe",
                                    code: 1003, message: "本次验证已达到接收数量或长度上限。"))
            return
        }
        vendorProtocol.recordNotification(channel: channel, byteCount: data.count)
        // File notifications are counted, never interpreted as identity replies.
        guard channel == .command else { return }
        let decodedEvents = vendorDecoder.append(data)
        vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
        let incomingCapabilities = decodedEvents.compactMap { event -> OppoTransportCapabilities? in
            if case .capabilities(let value) = event { return value }
            return nil
        }
        do {
            try VendorCapabilitySelection.validate(
                selected: vendorProtocol.authentication.selectedCapabilities,
                response: vendorProtocol.capabilities,
                unsolicited: vendorDecoder.diagnostics.unsolicitedCapabilities,
                incoming: incomingCapabilities)
        } catch {
            if let newest = incomingCapabilities.last {
                vendorProtocol.capabilities = newest
                vendorProtocol.responseAt = Date()
                vendorProtocol.responseCorrelation = "MESSAGE_STARTED_AFTER_QUERY_NO_TRANSACTION_ID"
            }
            vendorProbeFailed(.init(phase: "CAPABILITY_VALIDATION", domain: "WatchLink.ProtocolProbe",
                                    code: 2006, message: "同一连接中的完整能力消息参数冲突，已停止身份验证。"))
            return
        }
        for event in decodedEvents {
            guard isCheckingVendorProtocol else { return }
            switch event {
            case .capabilities(let capabilities):
                vendorProtocol.capabilities = capabilities
                vendorProtocol.responseAt = Date()
                vendorProtocol.responseCorrelation = "MESSAGE_STARTED_AFTER_QUERY_NO_TRANSACTION_ID"
                if authentication == nil {
                    vendorProtocol.status = "CAPABILITIES_WAITING_FOR_WRITE"
                    addEvent("已取得完整有效的协议能力消息，等待查询写入完成后进入身份验证。")
                    beginAuthenticationIfReady()
                }
            case .message(let message):
                if let authentication { handleAuthenticationActions(authentication.receive(message)) }
            case .rejected(let error):
                vendorProbeFailed(.init(phase: "PROTOCOL_DECODE", domain: "WatchLink.OppoProtocol",
                                        code: 1004, message: "协议接收停止：\(error.diagnosticMessage)"))
            }
        }
        guard isCheckingVendorProtocol else { return }
        beginAuthenticationIfReady()
        stateText = vendorProtocol.summary
    }

    private func vendorProbeFailed(_ error: VendorGATTTransport.Failure) {
        recordVendorNotifications()
        _ = vendorDecoder.finish()
        vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
        if let authentication {
            syncAuthenticationObservations()
            vendorProtocol.authentication.status = "FAILED"
            vendorProtocol.authentication.phase = .failed
            vendorProtocol.vendorAuthentication = "FAILED"
            authentication.cancel()
        }
        authentication = nil
        vendorProtocol.status = "FAILED"
        vendorProtocol.error = error
        isCheckingVendorProtocol = false
        cancelTimer()
        vendorTransport?.cancel()
        vendorDecoder.reset()
        phase = isConnected ? .ready : .idle
        result = "VENDOR_VERIFICATION_FAILED"
        stateText = vendorProtocol.summary
        addEvent("连接验证停止：\(error.description)。本次结果已保留；重新验证前请先断开并重连。")
    }

    private static func propertyLabels(_ properties: CBCharacteristicProperties) -> [String] {
        var labels: [String] = []
        if properties.contains(.read) { labels.append("read") }
        if properties.contains(.write) { labels.append("write") }
        if properties.contains(.writeWithoutResponse) { labels.append("writeWithoutResponse") }
        if properties.contains(.notify) { labels.append("notify") }
        if properties.contains(.indicate) { labels.append("indicate") }
        if properties.contains(.authenticatedSignedWrites) { labels.append("signedWrites") }
        if properties.contains(.extendedProperties) { labels.append("extendedProperties") }
        return labels
    }
}
