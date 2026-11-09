import Foundation

/// The verified, bounded beginning of the vendor's first-setup flow. This sends
/// StartSetting (11/7), then queries SyncOOBEState (11/11) and observes 11/11 or
/// 11/12. It does not perform cloud binding, account migration or final sync.
/// The owner supplies complete, decrypted, validated messages from this one
/// authenticated connection and acknowledges each whole logical ATT command.
final class OppoSetup {
    enum Phase: String, Codable {
        case idle = "NOT_STARTED"
        case startSetting = "START_SETTING"
        case queryState = "QUERY_OOBE_STATE"
        case observing = "OBSERVING_DEVICE_STATE"
        case completed = "OBSERVATION_FINISHED"
        case failed = "FAILED"
        case cancelled = "CANCELLED"
    }

    struct Command {
        let token: Int
        let phase: Phase
        let serviceID: UInt8
        let commandID: UInt8
        let protobuf: Data
    }

    enum Outcome: String, Codable, Equatable {
        case deviceReportedFinished = "DEVICE_SETUP_FINISHED_REPORTED"
        case awaitingDevice = "DEVICE_SETUP_PENDING"
        case unrecognizedState = "DEVICE_STATE_UNRECOGNIZED"
    }

    struct Failure: Error, Codable, Equatable {
        let phase: Phase
        let code: String
        let message: String
    }

    enum Action {
        case send(Command)
        case observed(StateObservation)
        case finished(Outcome)
        case failed(Failure)
    }

    enum StateInterpretation: String, Codable {
        case notStarted = "SETUP_NOT_STARTED"
        case inProgress = "SETUP_IN_PROGRESS"
        case finishedReported = "DEVICE_SETUP_FINISHED_REPORTED"
        case unknown = "UNRECOGNIZED_STATE"
    }

    /// Safe numeric state metadata only; never a device identifier or account.
    struct StateObservation: Codable, Equatable {
        let result: Int
        let deviceType: Int?
        let oobeFrom: Int?
        let encodedFieldNumbers: [Int]
        let commandID: Int
        let streamOffset: Int
        let observedAt: Date
        let source: String

        var interpretation: StateInterpretation {
            // OobeBusiness.q() uses !devicemanager.util.x.e(mac, result).
            // The watch path treats 0 and 10...59 as unfinished. We accept the
            // observed terminal boundary 60 only, not every other integer as
            // the original broad negation does. This is no account proof.
            if result == 0 { return .notStarted }
            if (10...59).contains(result) { return .inProgress }
            if result == 60 { return .finishedReported }
            return .unknown
        }

        var summary: String {
            switch interpretation {
            case .notStarted: return "手表报告首次设置尚未开始（状态 0）"
            case .inProgress: return "手表报告首次设置仍在进行（状态 \(result)）"
            case .finishedReported: return "手表报告首次设置已完成（状态 60）"
            case .unknown: return "收到尚未识别的首次设置状态（\(result)）"
            }
        }
    }

    struct Diagnostics: Codable, Equatable {
        var ignoredMessageCount = 0
        var preSubmissionMessageCount = 0
        var staleMessageCount = 0
        var echoMessageCount = 0
        var preQueryStateCount = 0
        var bufferedStateCount = 0
        var observedStateCount = 0
        var duplicateStateCount = 0
        var lastIgnoredReason: String?
    }

    private struct PendingCommand {
        let command: Command
        var streamOffset: Int?
        var writeSucceeded = false
    }

    private let now: () -> Date
    private var pending: PendingCommand?
    private var nextToken = 0
    private var startSubmissionOffset: Int?
    private var bufferedStates: [StateObservation] = []
    private(set) var snapshot = OppoSetupSnapshot()

    init(now: @escaping () -> Date = Date.init) { self.now = now }

    var phase: Phase { snapshot.phase }

    func start() -> [Action] {
        guard snapshot.phase == .idle else { return [] }
        snapshot.startedAt = now()
        // StartSetting.field1=1, field2=2, as do.c.f() constructs it.
        // Fixed bytes are a reviewed request, never supplied by user/report data.
        return send(command: 7, body: Data([0x08, 0x01, 0x10, 0x02]), phase: .startSetting)
    }

    /// Called immediately before a command's first physical write, not enqueue.
    func didSubmit(token: Int, streamOffset: Int) -> [Action] {
        guard snapshot.isRunning, var current = pending,
              current.command.token == token, current.streamOffset == nil else { return [] }
        guard streamOffset >= 0 else {
            return abort(code: "INVALID_SUBMISSION_OFFSET", message: "无法确定本次首次设置请求的接收流起点。")
        }
        if current.command.phase == .queryState,
           let startSubmissionOffset, streamOffset < startSubmissionOffset {
            return abort(code: "INVALID_SUBMISSION_OFFSET", message: "首次设置查询的接收流起点早于开始设置请求。")
        }
        current.streamOffset = streamOffset
        pending = current
        if current.command.phase == .startSetting { startSubmissionOffset = streamOffset }
        return []
    }

    /// One callback for the whole logical command, after all ATT fragments.
    func writeCompleted(token: Int, succeeded: Bool) -> [Action] {
        guard snapshot.isRunning, var current = pending,
              current.command.token == token, current.streamOffset != nil,
              !current.writeSucceeded else { return [] }
        guard succeeded else {
            return abort(code: "ATT_WRITE_FAILED", message: "首次设置消息没有获得完整的蓝牙写入确认。")
        }
        current.writeSucceeded = true
        pending = current
        if current.command.phase == .startSetting {
            snapshot.startWriteAcknowledged = true
            // APK OobeBusiness.C() sends 11/11 with an empty protobuf payload.
            // A successful StartSetting write is not a setup/binding success.
            return send(command: 11, body: Data(), phase: .queryState)
        }
        snapshot.queryWriteAcknowledged = true
        snapshot.phase = .observing
        snapshot.status = "OBSERVING_DEVICE_STATE"
        let queued = bufferedStates
        bufferedStates.removeAll()
        var actions: [Action] = []
        for observation in queued where snapshot.isRunning {
            actions += accept(observation)
        }
        return actions
    }

    func receive(_ message: OppoWireMessage) -> [Action] {
        guard snapshot.isRunning, let current = pending else { return [] }
        guard message.serviceID == 11 else { return ignore("OTHER_SERVICE") }
        let command = message.commandID & 0x7f
        guard command == 11 || command == 12 else {
            if command == 7, message.protobuf == Data([0x08, 0x01, 0x10, 0x02]) {
                snapshot.diagnostics.echoMessageCount += 1
                return ignore("START_SETTING_REQUEST_ECHO")
            }
            return ignore("OTHER_SETUP_COMMAND")
        }
        // The owner has already authenticated the transport mode and decrypted
        // encrypted payloads. Preserve the real control for provenance.
        guard message.controlFlags & ~UInt16(0x004b) == 0 else {
            return ignore("UNSUPPORTED_SETUP_CONTROL")
        }
        guard let startBoundary = startSubmissionOffset else {
            snapshot.diagnostics.preSubmissionMessageCount += 1
            return ignore("STATE_BEFORE_START_SETTING_SUBMISSION")
        }
        guard message.streamOffset >= startBoundary else {
            snapshot.diagnostics.staleMessageCount += 1
            return ignore("STATE_STARTED_BEFORE_START_SETTING")
        }
        // An empty 11/11 is indistinguishable from our exact query echo; even an
        // empty notification cannot prove a meaningful all-default state.
        guard !message.protobuf.isEmpty else {
            snapshot.diagnostics.echoMessageCount += 1
            return ignore("EMPTY_STATE_OR_QUERY_ECHO")
        }
        let queryBoundary = current.command.phase == .queryState ? current.streamOffset : nil
        let isPreQuery = queryBoundary.map { message.streamOffset < $0 } ?? true
        let source = isPreQuery
            ? (queryBoundary == nil ? "BEFORE_QUERY_SUBMISSION" : "STARTED_BEFORE_QUERY_SUBMISSION")
            : "AFTER_QUERY_SUBMISSION_NO_TRANSACTION_ID"
        let observation: StateObservation
        do {
            observation = try decode(message, source: source)
        } catch {
            if isPreQuery { return ignore("INVALID_PRE_QUERY_STATE") }
            return abort(code: "INVALID_OOBE_STATE", message: "首次设置状态回应的字段或格式无法验证。")
        }
        if isPreQuery {
            snapshot.preQueryObservation = observation
            snapshot.diagnostics.preQueryStateCount += 1
            return ignore("STATE_OBSERVED_BEFORE_QUERY_BOUNDARY")
        }
        guard current.writeSucceeded else {
            guard bufferedStates.count < 8 else {
                return abort(code: "EARLY_STATE_BUDGET_EXCEEDED", message: "查询写入确认前收到过多状态回应，已停止本轮设置。")
            }
            bufferedStates.append(observation)
            snapshot.diagnostics.bufferedStateCount += 1
            return []
        }
        return accept(observation)
    }

    /// The owner uses one fixed observation deadline from actual query submission.
    /// Progress messages must not extend it indefinitely.
    func timeout() -> [Action] {
        guard snapshot.isRunning else { return [] }
        guard snapshot.queryWriteAcknowledged, let last = snapshot.latestObservation else {
            let message = snapshot.preQueryObservation == nil
                ? "等待首次设置写入确认或有效状态回应超时。"
                : "已收到查询前的主动状态，但本次查询未取得完整写入确认及有效回应。"
            return abort(code: "OOBE_STATE_TIMEOUT", message: message)
        }
        return finish(last.interpretation == .unknown ? .unrecognizedState : .awaitingDevice)
    }

    func abort(code: String, message: String) -> [Action] {
        guard snapshot.isRunning else { return [] }
        let failure = Failure(phase: snapshot.phase, code: code, message: message)
        snapshot.error = failure
        snapshot.phase = .failed
        snapshot.status = "FAILED"
        snapshot.completedAt = now()
        releasePending()
        return [.failed(failure)]
    }

    func cancel() {
        guard snapshot.phase == .idle || snapshot.isRunning else { return }
        snapshot.phase = .cancelled
        snapshot.status = "INTERRUPTED"
        snapshot.completedAt = now()
        releasePending()
    }

    private func send(command: UInt8, body: Data, phase: Phase) -> [Action] {
        nextToken += 1
        let command = Command(token: nextToken, phase: phase, serviceID: 11,
                              commandID: command, protobuf: body)
        pending = PendingCommand(command: command)
        snapshot.phase = phase
        snapshot.status = phase.rawValue
        return [.send(command)]
    }

    private func decode(_ message: OppoWireMessage, source: String) throws -> StateObservation {
        let fields = try OppoProtobufReader(message.protobuf, fields: [1: .varint, 2: .varint, 3: .varint])
        guard !fields.presentFieldNumbers.isEmpty else { throw StateDecodeFailure.noKnownFields }
        // Proto3 can omit result=0; preserve its encoded-field provenance. A
        // missing field can never become terminal 60. Negative int32 values
        // have the protobuf's canonical sign-extended representation and remain
        // unknown states; an out-of-range integer cannot wrap into status 60.
        func value(_ field: Int) throws -> Int? {
            guard let raw = try fields.uint64(field) else { return nil }
            guard let integer = Int32(exactly: Int64(bitPattern: raw)) else {
                throw StateDecodeFailure.int32OutOfRange
            }
            return Int(integer)
        }
        return StateObservation(result: try value(1) ?? 0, deviceType: try value(2),
                                oobeFrom: try value(3), encodedFieldNumbers: fields.presentFieldNumbers,
                                commandID: Int(message.commandID), streamOffset: message.streamOffset,
                                observedAt: now(), source: source)
    }

    private func accept(_ observation: StateObservation) -> [Action] {
        snapshot.diagnostics.observedStateCount += 1
        if let last = snapshot.latestObservation,
           last.result == observation.result, last.deviceType == observation.deviceType,
           last.oobeFrom == observation.oobeFrom {
            snapshot.diagnostics.duplicateStateCount += 1
        }
        snapshot.latestObservation = observation
        snapshot.observations.append(observation)
        if snapshot.observations.count > 16 { snapshot.observations.removeFirst() }
        var actions: [Action] = [.observed(observation)]
        if observation.interpretation == .finishedReported {
            actions += finish(.deviceReportedFinished)
        }
        return actions
    }

    private func finish(_ outcome: Outcome) -> [Action] {
        snapshot.phase = .completed
        snapshot.status = outcome.rawValue
        snapshot.completedAt = now()
        releasePending()
        return [.finished(outcome)]
    }

    private func ignore(_ reason: String) -> [Action] {
        snapshot.diagnostics.ignoredMessageCount += 1
        snapshot.diagnostics.lastIgnoredReason = reason
        return []
    }

    private func releasePending() {
        pending = nil
        bufferedStates.removeAll()
        startSubmissionOffset = nil
    }

    private enum StateDecodeFailure: Error { case noKnownFields, int32OutOfRange }
}
