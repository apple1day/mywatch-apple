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

    private enum PendingAction { case scan, connect(UUID) }
    private enum Phase { case idle, waiting, scanning, connecting, services, characteristics, reading, ready }
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

    var selectedDevice: DiscoveredDevice? {
        devices.first { $0.id == selectedDeviceID }
    }

    var canConnect: Bool {
        guard let selectedDevice else { return false }
        return !isScanning && !isConnecting && !isConnected
            && selectedDevice.isConnectable != false
    }

    var canExportReport: Bool { selectedDeviceID != nil || !events.isEmpty }

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
            schemaVersion: 1,
            generatedAt: Date(),
            platform: PlatformSnapshot(
                system: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                deviceType: UIDevice.current.model,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
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
            privacy: "设备标识为本次启动加盐摘要；不包含完整 Core Bluetooth 设备 UUID、MAC 地址、原始广播载荷或私有特征值。设备名和标准设备信息仍可能识别你的设备。"
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
        return "（系统错误码 \((error as NSError).code)）"
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
            result = "GATT_DIAGNOSTICS_COMPLETE"
            stateText = "GATT 检测完成 · 一代主连接仍未适配"
            addEvent(readings.isEmpty ? "未发现可读取的标准电量／设备信息字段。没有标准字段不能单独证明不兼容。" : "已完成标准字段读取；没有执行私有认证、绑定或控制写入。")
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
        guard current(device, token: token), phase == .reading, characteristic === expectedRead else { return }
        cancelTimer()
        expectedRead = nil
        let uuid = WatchProfile.normalizeUUID(characteristic.uuid.uuidString)
        guard let label = WatchProfile.standardLabel(uuid) else { readNextValue(); return }
        let parsed = error == nil ? WatchProfile.standardValue(uuid: uuid, data: characteristic.value)
            : (value: "读取失败\(errorSuffix(error))", status: "READ_ERROR")
        readings.append(StandardReading(uuid: uuid, label: label, value: parsed.value, status: parsed.status))
        readNextValue()
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
