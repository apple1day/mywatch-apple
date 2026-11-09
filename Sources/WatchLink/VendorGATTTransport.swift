import Foundation
import CoreBluetooth

/// A single-use OPPO_AT transport attached to the monitor's current connection.
/// All calls and callbacks must run on the main thread. The owner must forward only
/// callbacks from this connection's delegate generation, and retire the connection
/// before replacing a cancelled transport that still had an ATT request in flight.
/// This class neither interprets vendor messages nor declares authentication success.
final class VendorGATTTransport {
    enum Channel: String, Codable {
        case command
        case file
    }

    struct Failure: Error, Codable, Equatable, CustomStringConvertible {
        let phase: String
        let domain: String
        let code: Int
        let message: String

        init(phase: String, domain: String, code: Int, message: String) {
            self.phase = Self.bounded(phase, limit: 64)
            self.domain = Self.bounded(domain, limit: 160)
            self.code = code
            self.message = Self.bounded(message, limit: 240)
        }

        var description: String { "\(phase): \(domain) (\(code)) \(message)" }

        private static func bounded(_ value: String, limit: Int) -> String {
            let cleaned = value.unicodeScalars.map { scalar -> String in
                CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            }.joined()
            return String(cleaned.prefix(limit))
        }
    }

    private enum State { case idle, subscribing, ready, failed, cancelled }

    private static let commandService = CBUUID(string: OppoGATTProfile.commandService)
    private static let commandWriteUUID = CBUUID(string: OppoGATTProfile.commandWrite)
    private static let commandNotifyUUID = CBUUID(string: OppoGATTProfile.commandNotify)
    private static let fileService = CBUUID(string: OppoGATTProfile.fileService)
    private static let fileNotifyUUID = CBUUID(string: OppoGATTProfile.fileNotify)
    private static let errorDomain = "WatchLink.VendorGATTTransport"
    private static let maximumFragments = 64
    private static let maximumOutgoingBytes = 64 * 1024
    private static let maximumIncomingValueBytes = 4 * 1024

    private let peripheral: CBPeripheral
    private let commandWrite: CBCharacteristic
    private let commandNotify: CBCharacteristic
    private let fileNotify: CBCharacteristic?
    private let onReady: () -> Void
    private let onReceived: (Channel, Data) -> Void
    private let onWriteComplete: () -> Void
    private let onFailure: (Failure) -> Void

    private var state: State = .idle
    private var subscriptionQueue: [CBCharacteristic] = []
    private var expectedSubscription: CBCharacteristic?
    private var outgoing: [Data] = []
    private var outgoingIndex = 0
    private var outgoingFragmentsAccepted = 0
    private var outgoingBytesAccepted = 0
    private var awaitingWriteAcknowledgement = false
    private var deadline: DispatchWorkItem?
    private var deadlineGeneration: UInt64 = 0

    /// Last observed subscription states, retained on failure/cancel for diagnostics.
    /// They do not certify the current link, system pairing, or vendor authentication.
    private(set) var commandNotificationsEnabled = false
    private(set) var fileNotificationsEnabled = false

    var isReady: Bool { state == .ready }
    var isWriting: Bool { !outgoing.isEmpty }
    var maximumWriteLength: Int {
        guard peripheral.state == .connected else { return 0 }
        return peripheral.maximumWriteValueLength(for: .withResponse)
    }

    init(peripheral: CBPeripheral,
         commandWrite: CBCharacteristic,
         commandNotify: CBCharacteristic,
         fileNotify: CBCharacteristic? = nil,
         onReady: @escaping () -> Void,
         onReceived: @escaping (Channel, Data) -> Void,
         onWriteComplete: @escaping () -> Void,
         onFailure: @escaping (Failure) -> Void) {
        self.peripheral = peripheral
        self.commandWrite = commandWrite
        self.commandNotify = commandNotify
        self.fileNotify = fileNotify
        self.onReady = onReady
        self.onReceived = onReceived
        self.onWriteComplete = onWriteComplete
        self.onFailure = onFailure
    }

    deinit { deadline?.cancel() }

    /// Idempotent: a failed or cancelled instance cannot be restarted.
    func start() {
        requireMainThread()
        guard state == .idle else { return }
        guard peripheral.state == .connected else {
            reject(phase: "PROFILE_VALIDATION", code: 1, message: "GATT 连接尚未建立。")
            return
        }
        guard matches(commandWrite, service: Self.commandService, uuid: Self.commandWriteUUID),
              commandWrite.properties.contains(.write),
              matches(commandNotify, service: Self.commandService, uuid: Self.commandNotifyUUID),
              commandWrite.service === commandNotify.service,
              commandNotify.properties.contains(.notify) else {
            reject(phase: "PROFILE_VALIDATION", code: 2, message: "命令服务或特征与已核实的 OPPO_AT 通道不匹配。")
            return
        }
        if let fileNotify {
            guard matches(fileNotify, service: Self.fileService, uuid: Self.fileNotifyUUID),
                  fileNotify.properties.contains(.notify) else {
                reject(phase: "PROFILE_VALIDATION", code: 2, message: "文件通知特征与已核实的 OPPO_AT 通道不匹配。")
                return
            }
        }
        state = .subscribing
        subscriptionQueue = [commandNotify]
        if let fileNotify { subscriptionQueue.append(fileNotify) }
        subscribeNext()
    }

    /// Accepts already framed protocol fragments. No frame is split or rewritten.
    /// Returns false without sending if not ready or another message is in flight.
    /// Validation failures terminate this transport and report onFailure.
    @discardableResult
    func send(fragments: [Data]) -> Bool {
        requireMainThread()
        guard state == .ready, !isWriting else { return false }
        let maximumLength = maximumWriteLength
        guard maximumLength > 0 else {
            reject(phase: "COMMAND_WRITE", code: 1, message: "GATT 连接已不可用于写入。")
            return false
        }
        guard !fragments.isEmpty,
              fragments.count <= Self.maximumFragments - outgoingFragmentsAccepted else {
            reject(phase: "COMMAND_WRITE", code: 3, message: "协议分片数量为空或超过上限。")
            return false
        }
        var total = 0
        for fragment in fragments {
            guard !fragment.isEmpty,
                  fragment.count <= maximumLength,
                  fragment.count <= Self.maximumOutgoingBytes - outgoingBytesAccepted - total else {
                reject(phase: "COMMAND_WRITE", code: 3, message: "协议分片为空、超过实际 ATT 写入长度或总量上限。")
                return false
            }
            total += fragment.count
        }
        outgoingFragmentsAccepted += fragments.count
        outgoingBytesAccepted += total
        outgoing = fragments
        outgoingIndex = 0
        writeNext()
        return true
    }

    /// Stops local work only. The owner controls disconnection and radio lifetime.
    func cancel() {
        requireMainThread()
        guard state != .cancelled else { return }
        state = .cancelled
        clearPendingWork()
    }

    func notificationStateChanged(_ device: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        requireMainThread()
        guard device === peripheral, state == .subscribing || state == .ready,
              let channel = channel(for: characteristic) else { return }
        let wasEnabled = channel == .command ? commandNotificationsEnabled : fileNotificationsEnabled
        recordNotificationState(characteristic, channel: channel)
        if state == .ready {
            if let error { fail(phase: notificationPhase(channel), error: error) }
            else if !characteristic.isNotifying {
                reject(phase: notificationPhase(channel), code: 4, message: "已启用的通知通道被关闭。")
            }
            return
        }
        guard characteristic === expectedSubscription else {
            // A previously enabled command channel may be lost while the file
            // notification subscription is still pending.
            if wasEnabled {
                if let error { fail(phase: notificationPhase(channel), error: error) }
                else if !characteristic.isNotifying {
                    reject(phase: notificationPhase(channel), code: 4, message: "通知初始化期间，已启用的通道被关闭。")
                }
            }
            return
        }
        cancelDeadline()
        expectedSubscription = nil
        if let error { fail(phase: notificationPhase(channel), error: error); return }
        guard characteristic.isNotifying else {
            reject(phase: notificationPhase(channel), code: 4, message: "系统回调未确认通知通道已启用。")
            return
        }
        subscribeNext()
    }

    func valueUpdated(_ device: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        requireMainThread()
        guard device === peripheral, state == .subscribing || state == .ready,
              let channel = channel(for: characteristic) else { return }
        let phase = channel == .command ? "COMMAND_RECEIVE" : "FILE_RECEIVE"
        if let error { fail(phase: phase, error: error); return }
        guard let data = characteristic.value else {
            reject(phase: phase, code: 5, message: "通知回调没有携带数据。")
            return
        }
        guard data.count <= Self.maximumIncomingValueBytes else {
            reject(phase: phase, code: 6, message: "单次通知超过接收大小上限。")
            return
        }
        // The owner's stream decoder must see every command byte from the first
        // notification, including traffic arriving before subscription setup ends.
        // Query provenance belongs to that decoder, not a transport delivery delay.
        onReceived(channel, data)
    }

    func writeCompleted(_ device: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        requireMainThread()
        guard device === peripheral, state == .ready, characteristic === commandWrite,
              awaitingWriteAcknowledgement, isWriting else { return }
        cancelDeadline()
        awaitingWriteAcknowledgement = false
        if let error { fail(phase: "COMMAND_WRITE", error: error); return }
        outgoingIndex += 1
        if outgoingIndex == outgoing.count {
            outgoing = []
            outgoingIndex = 0
            // ATT completion is deliberately separate from the protocol reply.
            onWriteComplete()
        } else {
            writeNext()
        }
    }

    private func subscribeNext() {
        guard state == .subscribing else { return }
        guard peripheral.state == .connected else {
            reject(phase: "NOTIFICATION_SETUP", code: 1, message: "启用通知时 GATT 连接已断开。")
            return
        }
        while !subscriptionQueue.isEmpty {
            let characteristic = subscriptionQueue.removeFirst()
            guard let channel = channel(for: characteristic) else { continue }
            recordNotificationState(characteristic, channel: channel)
            if characteristic.isNotifying { continue }
            expectedSubscription = characteristic
            setDeadline(seconds: 90, phase: notificationPhase(channel), code: 7,
                        message: "通知启用超时；请完成 iOS 系统配对提示后重新连接。")
            peripheral.setNotifyValue(true, for: characteristic)
            return
        }
        cancelDeadline()
        expectedSubscription = nil
        state = .ready
        onReady()
    }

    private func writeNext() {
        guard state == .ready, outgoingIndex < outgoing.count else { return }
        guard peripheral.state == .connected else {
            reject(phase: "COMMAND_WRITE", code: 1, message: "写入过程中 GATT 连接已断开。")
            return
        }
        guard outgoing[outgoingIndex].count <= maximumWriteLength else {
            reject(phase: "COMMAND_WRITE", code: 3, message: "协议分片超过当前 ATT 写入长度。")
            return
        }
        awaitingWriteAcknowledgement = true
        setDeadline(seconds: 20, phase: "COMMAND_WRITE", code: 8,
                    message: "等待 ATT 写入确认超时；未认定设备协议响应成功。")
        peripheral.writeValue(outgoing[outgoingIndex], for: commandWrite, type: .withResponse)
    }

    private func matches(_ characteristic: CBCharacteristic, service: CBUUID, uuid: CBUUID) -> Bool {
        guard let owner = characteristic.service else { return false }
        return owner.peripheral === peripheral && owner.uuid == service && characteristic.uuid == uuid
    }

    private func channel(for characteristic: CBCharacteristic) -> Channel? {
        if characteristic === commandNotify { return .command }
        if let fileNotify, characteristic === fileNotify { return .file }
        return nil
    }

    private func recordNotificationState(_ characteristic: CBCharacteristic, channel: Channel) {
        switch channel {
        case .command: commandNotificationsEnabled = characteristic.isNotifying
        case .file: fileNotificationsEnabled = characteristic.isNotifying
        }
    }

    private func notificationPhase(_ channel: Channel) -> String {
        channel == .command ? "COMMAND_SUBSCRIPTION" : "FILE_SUBSCRIPTION"
    }

    private func setDeadline(seconds: TimeInterval, phase: String, code: Int, message: String) {
        cancelDeadline()
        let generation = deadlineGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.deadlineGeneration == generation,
                  self.state != .failed, self.state != .cancelled else { return }
            self.reject(phase: phase, code: code, message: message)
        }
        deadline = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func cancelDeadline() {
        deadlineGeneration &+= 1
        deadline?.cancel()
        deadline = nil
    }

    private func clearPendingWork() {
        cancelDeadline()
        subscriptionQueue = []
        expectedSubscription = nil
        outgoing = []
        outgoingIndex = 0
        awaitingWriteAcknowledgement = false
    }

    private func reject(phase: String, code: Int, message: String) {
        finishFailure(Failure(phase: phase, domain: Self.errorDomain, code: code, message: message))
    }

    private func fail(phase: String, error: Error) {
        let error = error as NSError
        finishFailure(Failure(phase: phase, domain: error.domain, code: error.code,
                              message: error.localizedDescription))
    }

    private func finishFailure(_ failure: Failure) {
        guard state != .failed, state != .cancelled else { return }
        state = .failed
        clearPendingWork()
        onFailure(failure)
    }

    private func requireMainThread() {
        precondition(Thread.isMainThread, "VendorGATTTransport requires the main thread")
    }
}
