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
    @Published private(set) var isSettingUp = false
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
    private var vendorDecoder = OppoTransportDecoder(emitAuthenticationMessages: true, emitBusinessMessages: true)
    private var capabilityQuery: VendorCapabilityQuery?
    private var activeCapabilityAttempt: Int?
    private var capabilityRetryWork: DispatchWorkItem?
    private var capabilityRetryRevision = 0
    // Four capability queries, four identity commands, two setup commands.
    private static let maximumLogicalCommands = 10
    private var authentication: OppoAuthentication?
    private var businessSession: OppoBusinessSession?
    private var setupEngine: OppoSetup?
    private var activeVendorWriteIndex: Int?
    private var activeAuthenticationToken: Int?
    private var activeSetupToken: Int?

    private var isVendorSessionLive: Bool { isCheckingVendorProtocol || businessSession != nil }

    var canStartInitialSetup: Bool {
        isConnected && phase == .ready && !isCheckingVendorProtocol && !isSettingUp
            && vendorProtocol.authentication.transportAuthenticated
            && vendorProtocol.businessSessionState == "READY" && businessSession != nil
            && vendorTransport?.isReady == true && vendorTransport?.isWriting == false
            && activeVendorWriteIndex == nil && setupEngine == nil
    }

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

    var initialSetupButtonTitle: String {
        if let setupEngine { return setupEngine.snapshot.buttonTitle }
        if !vendorProtocol.authentication.transportAuthenticated { return "请先完成身份验证" }
        if !canStartInitialSetup { return "请重连并重新验证身份" }
        return "继续首次设置"
    }

    /// Start only in the still-live, authenticated connection. This sends the
    /// original start-setting request, then observes real OOBE state messages.
    func startInitialSetup() {
        guard canStartInitialSetup else { return }
        let engine = OppoSetup()
        setupEngine = engine
        isSettingUp = true
        phase = .vendor
        vendorProtocol.businessSessionState = "RUNNING"
        vendorProtocol.status = "INITIAL_SETUP_RUNNING"
        result = "INITIAL_SETUP_RUNNING"
        addEvent("开始首次设置：发送原厂开始设置请求，再查询并观察手表状态。账号登录和云绑定尚未执行。")
        handleSetupActions(engine.start())
    }

    private func handleSetupActions(_ actions: [OppoSetup.Action],
                                    transportFailure: VendorGATTTransport.Failure? = nil) {
        if let setupEngine { vendorProtocol.initialSetup = setupEngine.snapshot }
        stateText = vendorProtocol.summary
        for action in actions {
            guard isSettingUp else { return }
            switch action {
            case .send(let command):
                sendSetupCommand(command)
            case .observed(let observation):
                addEvent("收到首次设置状态：\(observation.result)。此状态不代表账号绑定已完成。")
            case .finished:
                finishBusinessSession(status: "INITIAL_SETUP_OBSERVED", failure: nil)
            case .failed(let failure):
                let error = transportFailure ?? VendorGATTTransport.Failure(
                    phase: "INITIAL_SETUP", domain: "WatchLink.InitialSetup", code: 3100,
                    message: "\(failure.code)：\(failure.message)")
                finishBusinessSession(status: "INITIAL_SETUP_FAILED", failure: error)
            }
        }
    }

    private func sendSetupCommand(_ command: OppoSetup.Command) {
        guard let session = businessSession, let transport = vendorTransport,
              transport.isReady, !transport.isWriting, activeVendorWriteIndex == nil,
              let capabilities = vendorProtocol.authentication.selectedCapabilities else {
            businessSessionFailed(.init(phase: "SETUP_COMMAND_WRITE", domain: "WatchLink.InitialSetup",
                                        code: 3002, message: "首次设置所需的当前业务会话已不可用。"))
            return
        }
        do {
            let plaintext = Data([command.serviceID, command.commandID]) + command.protobuf
            let payload = try session.sealPayload(plaintext)
            let limit = min(min(20, capabilities.maxFrameSize),
                            min(capabilities.maxTransmissionUnit, transport.maximumWriteLength))
            let fragments = try OppoProtocol.encodePayload(payload, encrypted: session.isEncrypted,
                                                            maximumFrameLength: limit)
            guard vendorProtocol.commandWrites.count < Self.maximumLogicalCommands else { throw OppoWireError.tooManyFragments }
            var receipt = VendorCommandWriteSnapshot(commandID: Int(command.commandID),
                                                      stage: command.phase.rawValue, frameCount: fragments.count,
                                                      queuedAt: Date())
            receipt.serviceID = Int(command.serviceID)
            receipt.encrypted = session.isEncrypted
            vendorProtocol.commandWrites.append(receipt)
            activeVendorWriteIndex = vendorProtocol.commandWrites.count - 1
            activeAuthenticationToken = nil
            activeSetupToken = command.token
            addEvent("提交首次设置业务命令 \(command.serviceID)/\(command.commandID)，共 \(fragments.count) 个分片。")
            if !transport.send(fragments: fragments, intervalMilliseconds: max(10, capabilities.interval)),
               isSettingUp {
                vendorTransportFailed(.init(phase: "SETUP_COMMAND_WRITE", domain: "WatchLink.InitialSetup",
                                             code: 3003, message: "首次设置命令没有进入发送队列。"))
            }
        } catch {
            businessSessionFailed(.init(phase: "SETUP_FRAME_ENCODING", domain: "WatchLink.InitialSetup",
                                        code: 3004, message: "首次设置消息无法按当前加密模式和分片限额编码。"))
        }
    }

    private func receiveBusinessMessage(_ message: OppoWireMessage) {
        guard let session = businessSession else { return }
        do {
            let payload = Data([message.serviceID, message.commandID]) + message.protobuf
            _ = try session.openPayload(payload, encrypted: false)
            routeBusinessMessage(message)
        } catch {
            businessSessionFailed(.init(phase: "BUSINESS_ENCRYPTION", domain: "WatchLink.Session",
                                        code: 3005, message: "收到的业务消息与已协商的加密模式不一致。"))
        }
    }

    private func receiveEncryptedBusinessMessage(_ message: OppoEncryptedMessage) {
        guard let session = businessSession else {
            vendorProtocol.ignoredBusinessMessageCount += 1
            return
        }
        do {
            let plaintext = try session.openPayload(message.payload, encrypted: true)
            guard plaintext.count >= 2 else { throw OppoWireError.messageTooLarge }
            let bytes = Array(plaintext)
            let decoded = OppoWireMessage(
                serviceID: bytes[0], commandID: bytes[1], protobuf: Data(bytes.dropFirst(2)),
                streamOffset: message.streamOffset, controlFlags: message.controlFlags,
                frameCount: message.frameCount, frameShape: message.frameShape,
                crcValidation: message.crcValidation)
            routeBusinessMessage(decoded)
        } catch {
            businessSessionFailed(.init(phase: "BUSINESS_DECRYPT", domain: "WatchLink.Session",
                                        code: 3006, message: "业务消息无法使用本连接的协商参数验证并解密。"))
        }
    }

    private func routeBusinessMessage(_ message: OppoWireMessage) {
        guard message.serviceID == 11, [UInt8(7), 11, 12].contains(message.commandID & 0x7f),
              isSettingUp, let setupEngine else {
            vendorProtocol.ignoredBusinessMessageCount += 1
            return
        }
        handleSetupActions(setupEngine.receive(message))
    }

    private func businessSessionFailed(_ error: VendorGATTTransport.Failure) {
        if isSettingUp, let setupEngine {
            let actions = setupEngine.abort(code: "BUSINESS_CHANNEL_FAILED", message: error.message)
            handleSetupActions(actions, transportFailure: error)
            if !isSettingUp { return }
        }
        finishBusinessSession(status: "BUSINESS_SESSION_FAILED", failure: error)
    }

    private func finishBusinessSession(status: String, failure: VendorGATTTransport.Failure?) {
        if let setupEngine { vendorProtocol.initialSetup = setupEngine.snapshot }
        recordVendorNotifications()
        _ = vendorDecoder.finish()
        vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
        businessSession?.invalidate()
        businessSession = nil
        cancelCapabilityRetry()
        authentication?.cancel()
        authentication = nil
        vendorProtocol.businessSessionState = failure == nil ? "ENDED" : "FAILED"
        vendorProtocol.status = status
        vendorProtocol.error = failure
        isSettingUp = false
        isCheckingVendorProtocol = false
        cancelTimer()
        vendorTransport?.cancel()
        vendorDecoder.reset()
        activeSetupToken = nil
        activeAuthenticationToken = nil
        // Keep an in-flight receipt available for a genuine late ATT callback;
        // the cancelled transport cannot resume or advance the protocol.
        phase = isConnected ? .ready : .idle
        result = status
        stateText = vendorProtocol.summary
        addEvent(failure.map { "首次设置业务通道已停止：\($0.description)" }
                 ?? "本轮首次设置观察已结束：\(vendorProtocol.initialSetup.summary)。账号绑定未被认定成功。")
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
        cancelCapabilityRetry()
        capabilityQuery?.cancel()
        capabilityQuery = nil
        activeCapabilityAttempt = nil
        authentication?.cancel()
        authentication = nil
        businessSession?.invalidate()
        businessSession = nil
        setupEngine?.cancel()
        setupEngine = nil
        isSettingUp = false
        activeVendorWriteIndex = nil
        activeAuthenticationToken = nil
        activeSetupToken = nil
        vendorProtocol.status = "SUBSCRIBING"
        vendorProtocol.startedAt = Date()
        isCheckingVendorProtocol = true
        phase = .vendor
        result = "VENDOR_PROTOCOL_SUBSCRIBING"
        stateText = vendorProtocol.summary
        addEvent("开始连接与身份验证：先检查协议能力，再按手表实际版本验证身份；通过后可继续首次设置。账号绑定尚未接入。")

        let transport = VendorGATTTransport(
            peripheral: peripheral, commandWrite: write, commandNotify: notify, fileNotify: fileNotify,
            onReady: { [weak self] in
                guard let self, self.generation == token, self.isCheckingVendorProtocol else { return }
                self.recordVendorNotifications()
                self.beginVendorQuery()
            },
            onReceived: { [weak self] channel, data in
                guard let self, self.generation == token, self.isVendorSessionLive else { return }
                self.receiveVendorData(channel, data: data)
            },
            onFragmentSubmitted: { [weak self] index in
                guard let self, self.generation == token, self.isVendorSessionLive else { return }
                self.vendorFragmentSubmitted(index)
            },
            onWriteComplete: { [weak self] in
                guard let self, self.generation == token, self.isVendorSessionLive else { return }
                self.vendorWriteCompleted()
            },
            onFailure: { [weak self] error in
                guard let self, self.generation == token, self.isVendorSessionLive else { return }
                self.vendorTransportFailed(error)
            }
        )
        vendorTransport = transport
        transport.start()
        // A report exported before the first Core Bluetooth callback must
        // still distinguish a requested subscription from one never started.
        recordVendorNotifications()
    }

    private func beginVendorQuery() {
        guard capabilityQuery == nil, let transport = vendorTransport, transport.isReady else { return }
        let query = VendorCapabilityQuery()
        capabilityQuery = query
        if vendorProtocol.capabilities != nil || vendorDecoder.diagnostics.unsolicitedCapabilities != nil {
            _ = query.capabilitiesAvailable()
        }
        handleCapabilityQueryActions(query.start())
    }

    private func handleCapabilityQueryActions(_ actions: [VendorCapabilityQuery.Action]) {
        if let capabilityQuery { vendorProtocol.capabilityQuery = capabilityQuery.snapshot }
        for action in actions {
            guard isCheckingVendorProtocol, authentication == nil,
                  !vendorProtocol.authentication.transportAuthenticated else { return }
            switch action {
            case .send(let attempt):
                sendCapabilityQuery(attempt: attempt)
            case .scheduleRetry(let attempt, let seconds):
                scheduleCapabilityRetry(attempt: attempt, seconds: seconds)
            case .readyForAuthentication:
                cancelCapabilityRetry()
                beginAuthenticationIfReady()
            }
        }
    }

    private func sendCapabilityQuery(attempt: Int) {
        guard let transport = vendorTransport, transport.isReady, !transport.isWriting,
              activeVendorWriteIndex == nil,
              vendorProtocol.commandWrites.count < Self.maximumLogicalCommands else {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1002, message: "能力查询与当前写入状态或命令预算不一致。"))
            return
        }
        var receipt = VendorCommandWriteSnapshot(commandID: 1, stage: "TRANSPORT_QUERY",
                                                 frameCount: 1, queuedAt: Date())
        receipt.queryAttempt = attempt
        vendorProtocol.commandWrites.append(receipt)
        activeVendorWriteIndex = vendorProtocol.commandWrites.count - 1
        activeCapabilityAttempt = attempt
        activeAuthenticationToken = nil
        activeSetupToken = nil
        if !transport.send(fragments: [OppoProtocol.transportConsultRequest], intervalMilliseconds: 10), isCheckingVendorProtocol {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1002, message: "能力查询没有进入发送队列。"))
        }
    }

    private func observeAvailableCapabilities() {
        guard isCheckingVendorProtocol, authentication == nil, let capabilityQuery,
              vendorProtocol.capabilities != nil || vendorDecoder.diagnostics.unsolicitedCapabilities != nil else { return }
        cancelCapabilityRetry()
        handleCapabilityQueryActions(capabilityQuery.capabilitiesAvailable())
    }

    private func scheduleCapabilityRetry(attempt: Int, seconds: TimeInterval) {
        cancelCapabilityRetry()
        let token = generation
        let revision = capabilityRetryRevision
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.capabilityRetryRevision == revision,
                  self.isCheckingVendorProtocol, self.authentication == nil,
                  let query = self.capabilityQuery else { return }
            self.capabilityRetryWork = nil
            self.handleCapabilityQueryActions(query.retryTimerFired(attempt: attempt))
        }
        capabilityRetryWork = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelCapabilityRetry() {
        capabilityRetryRevision &+= 1
        capabilityRetryWork?.cancel()
        capabilityRetryWork = nil
    }

    private func vendorFragmentSubmitted(_ fragmentIndex: Int) {
        guard let index = activeVendorWriteIndex, vendorProtocol.commandWrites.indices.contains(index),
              vendorProtocol.commandWrites[index].recordSubmission(index: fragmentIndex, at: Date()) else {
            vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                    code: 1006, message: "发送分片与当前命令记录不一致。"))
            return
        }
        guard fragmentIndex == 0 else { return }
        if let token = activeSetupToken, let setupEngine {
            setTimer(seconds: 45) { [weak self] in
                guard let self, self.isSettingUp, let setupEngine = self.setupEngine else { return }
                self.handleSetupActions(setupEngine.timeout())
            }
            handleSetupActions(setupEngine.didSubmit(
                token: token, streamOffset: vendorDecoder.diagnostics.receivedByteCount))
        } else if let token = activeAuthenticationToken, let authentication {
            setTimer(seconds: 45) { [weak self] in
                guard let self, self.isCheckingVendorProtocol, let authentication = self.authentication else { return }
                self.handleAuthenticationActions(authentication.timeout())
            }
            handleAuthenticationActions(authentication.didSubmit(
                token: token, streamOffset: vendorDecoder.diagnostics.receivedByteCount))
        } else {
            guard let attempt = activeCapabilityAttempt, let capabilityQuery else {
                vendorProbeFailed(.init(phase: "COMMAND_WRITE", domain: "WatchLink.ProtocolProbe",
                                        code: 1006, message: "能力查询缺少本轮发送记录。"))
                return
            }
            if !vendorProtocol.requestSubmitted {
                // Retries keep the original receive-stream boundary and the
                // original total deadline; neither old fragments nor late
                // replies acquire a new request identity.
                vendorDecoder.markQuerySubmitted()
                vendorProtocol.requestSubmitted = true
                vendorProtocol.querySubmittedAt = Date()
                vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
                setTimer(seconds: 45) { [weak self] in
                    guard let self, self.isCheckingVendorProtocol, self.authentication == nil else { return }
                    let failure = self.vendorProtocol.recordCapabilityTimeout(
                        hasPendingData: self.vendorDecoder.hasPendingData)
                    self.vendorProbeFailed(failure)
                }
            }
            vendorProtocol.status = "WAITING_FOR_RESPONSE"
            result = "VENDOR_PROTOCOL_WAITING_FOR_RESPONSE"
            addEvent("提交第 \(attempt)/4 次传输能力查询；重试保留首轮接收边界，取得能力并完成当前写入后才进入身份验证。")
            handleCapabilityQueryActions(capabilityQuery.didSubmit(attempt: attempt))
            stateText = vendorProtocol.summary
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
        let setupToken = activeSetupToken
        let queryAttempt = activeCapabilityAttempt
        let commandID = vendorProtocol.commandWrites[index].commandID
        activeVendorWriteIndex = nil
        activeCapabilityAttempt = nil
        activeAuthenticationToken = nil
        activeSetupToken = nil
        if let setupToken, let setupEngine {
            addEvent("首次设置命令 \(commandID) 的全部分片已收到 ATT 确认；设备状态仍由实际回包判断。")
            handleSetupActions(setupEngine.writeCompleted(token: setupToken, succeeded: true))
        } else if let token, let authentication {
            addEvent("身份流程命令 \(commandID) 的全部分片已收到 ATT 确认；设备协议校验单独判断。")
            handleAuthenticationActions(authentication.writeCompleted(token: token, succeeded: true))
        } else if let queryAttempt, let capabilityQuery {
            addEvent("第 \(queryAttempt) 次能力查询的 ATT 写入已完整确认，设备能力仍以实际回包为准。")
            handleCapabilityQueryActions(capabilityQuery.writeCompleted(attempt: queryAttempt, succeeded: true))
        }
    }

    private func beginAuthenticationIfReady() {
        guard isCheckingVendorProtocol, authentication == nil, !vendorProtocol.authentication.transportAuthenticated,
              capabilityQuery?.isReadyForAuthentication == true,
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
        cancelCapabilityRetry()
        if let capabilityQuery { vendorProtocol.capabilityQuery = capabilityQuery.snapshot }
        capabilityQuery = nil
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
                guard let session = authentication?.takeBusinessSession() else {
                    vendorProbeFailed(.init(phase: "BUSINESS_SESSION_TRANSFER", domain: "WatchLink.Session",
                                            code: 3001, message: "身份已通过，但没有可移交的业务会话。请重新连接。"))
                    return
                }
                businessSession = session
                vendorProtocol.businessSessionState = "READY"
                vendorProtocol.businessEncrypted = session.isEncrypted
                vendorProtocol.status = "READY_FOR_INITIAL_SETUP"
                result = "READY_FOR_INITIAL_SETUP"
                isCheckingVendorProtocol = false
                phase = .ready
                cancelTimer()
                recordVendorNotifications()
                authentication = nil
                stateText = vendorProtocol.summary
                addEvent("协议版本 \(completion.protocolVersion) 的身份验证已通过；业务加密\(completion.encryptedTransport ? "已启用" : "未被手表要求")。当前连接已保留，可点击继续首次设置；账号绑定与健康同步尚未执行。")
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
            guard vendorProtocol.commandWrites.count < Self.maximumLogicalCommands else {
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
        if let capabilityQuery, let attempt = activeCapabilityAttempt {
            handleCapabilityQueryActions(capabilityQuery.writeCompleted(attempt: attempt, succeeded: false))
            if isCheckingVendorProtocol { vendorProbeFailed(failure) }
        } else if isSettingUp, let setupEngine, let token = activeSetupToken {
            handleSetupActions(setupEngine.writeCompleted(token: token, succeeded: false), transportFailure: failure)
            if isSettingUp { businessSessionFailed(failure) }
        } else if businessSession != nil {
            businessSessionFailed(failure)
        } else if let authentication, let token = activeAuthenticationToken {
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
            schemaVersion: 6,
            generatedAt: Date(),
            platform: PlatformSnapshot(
                system: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                deviceType: UIDevice.current.model,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.1",
                appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "6"
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
            privacy: "设备标识为本次启动加盐摘要；不包含完整 Core Bluetooth 设备 UUID、MAC 地址、原始广播载荷、验证码、密钥或原始私有载荷。仅记录传输能力、身份验证结果、首次设置状态码、逐命令写入计数及有界帧头。身份随机值、挑战、加密证明、会话密钥和 IV 仅在本连接内存中处理，不写入报告。前置主动消息单独标注来源，不作为本次查询应答。设备名和标准设备信息仍可能识别你的设备。",
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
        cancelCapabilityRetry()
        if let capabilityQuery {
            capabilityQuery.cancel()
            vendorProtocol.capabilityQuery = capabilityQuery.snapshot
        }
        capabilityQuery = nil
        activeCapabilityAttempt = nil
        recordVendorNotifications()
        if isVendorSessionLive {
            _ = vendorDecoder.finish()
            vendorProtocol.decoderDiagnostics = vendorDecoder.diagnostics
            if isSettingUp {
                setupEngine?.cancel()
                if let setupEngine { vendorProtocol.initialSetup = setupEngine.snapshot }
                vendorProtocol.status = "INITIAL_SETUP_INTERRUPTED"
            } else if isCheckingVendorProtocol {
                vendorProtocol.status = "INTERRUPTED"
            } else {
                vendorProtocol.status = "BUSINESS_SESSION_CLOSED"
            }
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
        businessSession?.invalidate()
        businessSession = nil
        if vendorProtocol.businessSessionState == "READY" || vendorProtocol.businessSessionState == "RUNNING" {
            vendorProtocol.businessSessionState = "INVALIDATED"
        }
        isSettingUp = false
        activeVendorWriteIndex = nil
        activeAuthenticationToken = nil
        activeSetupToken = nil
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
        setupEngine?.cancel()
        setupEngine = nil
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
        if isVendorSessionLive {
            let detail = error as NSError?
            vendorProtocol.error = .init(phase: "LINK_DISCONNECTED",
                                         domain: detail?.domain ?? "WatchLink.ProtocolProbe",
                                         code: detail?.code ?? 1005,
                                         message: "连接验证或首次设置期间 GATT 连接断开。")
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
               vendorProtocol.commandWrites[index].serviceID == 1,
               vendorProtocol.commandWrites[index].commandID == 1,
               vendorProtocol.commandWrites[index].queryAttempt == 1 {
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
        vendorProtocol.commandNotificationActivation = transport.commandNotificationActivation
        vendorProtocol.fileNotificationActivation = transport.fileNotificationActivation
        vendorProtocol.commandNotificationCallbackCount = transport.commandNotificationCallbackCount
        vendorProtocol.fileNotificationCallbackCount = transport.fileNotificationCallbackCount
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
            guard isVendorSessionLive else { return }
            switch event {
            case .capabilities(let capabilities):
                vendorProtocol.capabilities = capabilities
                vendorProtocol.responseAt = Date()
                vendorProtocol.responseCorrelation = "MESSAGE_STARTED_AFTER_QUERY_NO_TRANSACTION_ID"
                if isCheckingVendorProtocol && authentication == nil {
                    vendorProtocol.status = "CAPABILITIES_WAITING_FOR_WRITE"
                    addEvent("已取得完整有效的协议能力消息，等待查询写入完成后进入身份验证。")
                    observeAvailableCapabilities()
                }
            case .message(let message):
                if let authentication { handleAuthenticationActions(authentication.receive(message)) }
                else if message.serviceID == 11 { receiveBusinessMessage(message) }
                else { vendorProtocol.ignoredBusinessMessageCount += 1 }
            case .encryptedMessage(let message):
                receiveEncryptedBusinessMessage(message)
            case .rejected(let error):
                vendorProbeFailed(.init(phase: "PROTOCOL_DECODE", domain: "WatchLink.OppoProtocol",
                                        code: 1004, message: "协议接收停止：\(error.diagnosticMessage)"))
            }
        }
        guard isVendorSessionLive else { return }
        // A complete pre-query capability produces diagnostics, not a decoded
        // query-response event. It must still stop pending capability retries.
        observeAvailableCapabilities()
        beginAuthenticationIfReady()
        stateText = vendorProtocol.summary
    }

    private func vendorProbeFailed(_ error: VendorGATTTransport.Failure) {
        cancelCapabilityRetry()
        if let capabilityQuery {
            capabilityQuery.cancel()
            vendorProtocol.capabilityQuery = capabilityQuery.snapshot
        }
        capabilityQuery = nil
        activeCapabilityAttempt = nil
        if vendorProtocol.authentication.transportAuthenticated {
            businessSessionFailed(error)
            return
        }
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
