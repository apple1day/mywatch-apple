import Foundation

/// A deliberately narrow implementation of the APK's unencrypted transport
/// capability query. No identity, key, pairing, account or control commands exist
/// here. The wire description was independently reconstructed from ps0.g,
/// dt0.a and ConsultProto.TransportConsult in the supplied APK.
enum OppoProtocol {
    /// sid=1, cid=1; protobuf version=5, frame=20, MTU=20, interval=10,
    /// supportProtocol=3. The final two bytes are CRC16 in little-endian order.
    static let transportConsultRequest = Data([
        0xaa, 0x0e, 0x00, 0x00, 0x01, 0x01, 0x08, 0x05, 0x10,
        0x14, 0x18, 0x14, 0x20, 0x0a, 0x28, 0x03, 0x2c, 0x16
    ])

    static func crc16(_ data: Data) -> UInt16 {
        crc16(bytes: data)
    }

    fileprivate static func crc16<S: Sequence>(bytes: S) -> UInt16 where S.Element == UInt8 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) == 0 ? crc &<< 1 : (crc &<< 1) ^ 0x1021
            }
        }
        return crc
    }
}

/// Reported peer values, never negotiated limits and never proof of binding.
struct OppoTransportCapabilities: Codable, Equatable {
    let protocolVersion: Int
    let maxFrameSize: Int
    let maxTransmissionUnit: Int
    let interval: Int
    let supportProtocol: UInt32

    /// The APK accepts cid=1 and cid=0x81. Its bit-7 semantics are not assumed.
    let commandID: Int
    let controlFlags: UInt16
    let frameCount: Int
    let frameShape: String
    let crcValidation: String
    /// Proto3 can omit zero interval/support values. Keep their wire presence
    /// explicit instead of presenting an omitted default as a measured value.
    let encodedFieldNumbers: [Int]
}

enum OppoDecodeError: Error, Equatable {
    case invalidPreamble
    case invalidFrameLength
    case oversizedInput
    case oversizedFrame
    case oversizedMessage
    case incompleteFrame
    case checksumMismatch
    case encryptedFrame
    case unsupportedControl
    case unexpectedFragment
    case fragmentSequenceMismatch
    case interleavedMessage
    case unexpectedCommand(service: UInt8, command: UInt8)
    case malformedProtobuf
    case duplicateProtobufField
    case unsupportedProtobufField(UInt32)
    case missingRequiredFields
    case unsupportedProtocolVersion(UInt32)
    case invalidCapabilityValue(field: Int, value: UInt32)
    case loopbackOrEcho

    var rawValue: String {
        switch self {
        case .invalidPreamble: return "INVALID_PREAMBLE"
        case .invalidFrameLength: return "INVALID_FRAME_LENGTH"
        case .oversizedInput: return "OVERSIZED_INPUT"
        case .oversizedFrame: return "OVERSIZED_FRAME"
        case .oversizedMessage: return "OVERSIZED_MESSAGE"
        case .incompleteFrame: return "INCOMPLETE_FRAME"
        case .checksumMismatch: return "CRC_MISMATCH"
        case .encryptedFrame: return "ENCRYPTED_FRAME_UNSUPPORTED"
        case .unsupportedControl: return "UNSUPPORTED_CONTROL_FLAGS"
        case .unexpectedFragment: return "UNEXPECTED_FRAGMENT"
        case .fragmentSequenceMismatch: return "FRAGMENT_SEQUENCE_MISMATCH"
        case .interleavedMessage: return "INTERLEAVED_MESSAGE"
        case .unexpectedCommand: return "UNEXPECTED_SERVICE_OR_COMMAND"
        case .malformedProtobuf: return "MALFORMED_PROTOBUF"
        case .duplicateProtobufField: return "DUPLICATE_PROTOBUF_FIELD"
        case .unsupportedProtobufField: return "UNSUPPORTED_PROTOBUF_FIELD"
        case .missingRequiredFields: return "MISSING_REQUIRED_CAPABILITIES"
        case .unsupportedProtocolVersion: return "UNSUPPORTED_PROTOCOL_VERSION"
        case .invalidCapabilityValue: return "CAPABILITY_VALUE_OUT_OF_RANGE"
        case .loopbackOrEcho: return "LOOPBACK_OR_ECHO"
        }
    }

    /// Bounded numeric context only; no received packet bytes or user data.
    var diagnosticMessage: String {
        switch self {
        case .unexpectedCommand(let service, let command):
            return "\(rawValue): sid=\(service), cid=\(command)"
        case .unsupportedProtocolVersion(let version):
            return "\(rawValue): version=\(version)"
        case .unsupportedProtobufField(let field):
            return "\(rawValue): field=\(field)"
        case .invalidCapabilityValue(let field, let value):
            return "\(rawValue): field=\(field), value=\(value)"
        default:
            return rawValue
        }
    }
}

enum OppoDecodeEvent: Equatable {
    case capabilities(OppoTransportCapabilities)
    case rejected(OppoDecodeError)
}

/// Header/protocol metadata only. No raw characteristic or message payload is
/// retained in reports. The origin of a frame can differ from that of its
/// message when a fragmented message crosses the query submission boundary.
struct OppoFrameMetadata: Codable, Equatable {
    let streamOffset: Int
    let origin: String
    let messageOrigin: String?
    let byteCount: Int
    let bodyLength: Int
    let controlFlags: UInt16
    let fragmentType: Int
    let fragmentSequence: Int?
    let crcValidation: String
    let serviceID: Int?
    let commandID: Int?
    let disposition: String
}

struct OppoDecoderDiagnostics: Codable, Equatable {
    var receivedByteCount = 0
    var validatedFrameCount = 0
    var discardedByteCount = 0
    var crcFailureCount = 0
    var orphanFragmentCount = 0
    var sequenceGapCount = 0
    var replacedFragmentCount = 0
    var ignoredCommandCount = 0
    var encryptedFrameCount = 0
    var invalidCapabilityCount = 0
    var echoCount = 0
    var preQueryMessageCount = 0
    var postQueryMessageCount = 0
    var incompleteMessageCount = 0
    var droppedMessageCount = 0
    var lastIssue: String?
    var recentFrames: [OppoFrameMetadata] = []
    var unsolicitedCapabilities: OppoTransportCapabilities?
}

/// Feed all command notifications, including those received while subscribing.
/// Mark the query once immediately before submission, without flushing bytes or
/// fragments. Only a message whose first header starts after that boundary can
/// produce `.capabilities`. Unsolicited traffic and recoverable framing errors
/// are observations; only bounded-resource exhaustion stops this decoder.
struct OppoTransportDecoder {
    static let maximumFrameBodyLength = 512
    static let maximumMessageLength = 1024
    static let maximumBufferedLength = 4096
    static let maximumFragmentCount = 64
    static let maximumReceivedByteCount = 64 * 1024
    static let maximumRecentFrames = 32

    private var buffer: [UInt8] = []
    private var bufferStartOffset = 0
    private var queryBoundaryOffset: Int?
    private var fragmentPayload: [UInt8]?
    private var fragmentStartOffset: Int?
    private var lastFragmentSequence: UInt8?
    private var fragmentCount = 0
    private var fragmentCRCOrders: Set<CRCByteOrder> = []
    private var failed = false
    private(set) var diagnostics = OppoDecoderDiagnostics()

    var hasPendingData: Bool { !buffer.isEmpty || fragmentPayload != nil }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        bufferStartOffset = 0
        queryBoundaryOffset = nil
        clearFragments()
        failed = false
        diagnostics = OppoDecoderDiagnostics()
    }

    mutating func markQuerySubmitted() {
        guard queryBoundaryOffset == nil, !failed else { return }
        queryBoundaryOffset = diagnostics.receivedByteCount
    }

    mutating func append(_ data: Data) -> [OppoDecodeEvent] {
        guard !failed, !data.isEmpty else { return [] }
        guard data.count <= Self.maximumBufferedLength,
              buffer.count <= Self.maximumBufferedLength - data.count,
              diagnostics.receivedByteCount <= Self.maximumReceivedByteCount - data.count else {
            return [reject(.oversizedInput)]
        }
        buffer.append(contentsOf: data)
        diagnostics.receivedByteCount += data.count
        var events: [OppoDecodeEvent] = []
        var cursor = 0
        scan: while cursor < buffer.count {
            if buffer[cursor] != 0xaa {
                let nextHeader = buffer[(cursor + 1)...].firstIndex(of: 0xaa) ?? buffer.count
                diagnostics.discardedByteCount += nextHeader - cursor
                if diagnostics.lastIssue == nil { recordIssue(.invalidPreamble) }
                clearFragments()
                cursor = nextHeader
                continue
            }
            switch scanPacket(at: cursor) {
            case .incomplete:
                break scan
            case .invalid(let issue):
                recordIssue(issue)
                if issue == .checksumMismatch { diagnostics.crcFailureCount += 1 }
                diagnostics.discardedByteCount += 1
                clearFragments()
                cursor += 1
            case .packet(let packet):
                diagnostics.validatedFrameCount += 1
                if let event = process(packet) { events.append(event) }
                cursor += packet.byteCount
            }
        }
        if cursor > 0 {
            buffer.removeFirst(cursor)
            bufferStartOffset += cursor
        }
        return events
    }

    private mutating func clearFragments() {
        fragmentPayload = nil
        fragmentStartOffset = nil
        lastFragmentSequence = nil
        fragmentCount = 0
        fragmentCRCOrders.removeAll()
    }

    private func origin(of offset: Int) -> String {
        if let boundary = queryBoundaryOffset, offset >= boundary { return "POST_QUERY" }
        return "PRE_QUERY"
    }

    private mutating func recordIssue(_ issue: OppoDecodeError) {
        diagnostics.lastIssue = issue.diagnosticMessage
    }

    private mutating func recordFrame(_ packet: Packet, messageStart: Int?, payload: [UInt8]?, disposition: String) {
        let fragmentType = Int(packet.control & 3)
        let metadata = OppoFrameMetadata(
            streamOffset: packet.startOffset, origin: origin(of: packet.startOffset),
            messageOrigin: messageStart.map { origin(of: $0) }, byteCount: packet.byteCount,
            bodyLength: packet.bodyLength, controlFlags: packet.control, fragmentType: fragmentType,
            fragmentSequence: fragmentType == 0 ? nil : packet.payload.first.map(Int.init),
            crcValidation: Self.crcValidation(for: Set(packet.crcOrder.map { [$0] } ?? [])),
            serviceID: payload.flatMap { $0.count >= 2 ? Int($0[0]) : nil },
            commandID: payload.flatMap { $0.count >= 2 ? Int($0[1]) : nil }, disposition: disposition)
        diagnostics.recentFrames.append(metadata)
        if diagnostics.recentFrames.count > Self.maximumRecentFrames {
            diagnostics.recentFrames.removeFirst(diagnostics.recentFrames.count - Self.maximumRecentFrames)
        }
    }

    private mutating func process(_ packet: Packet) -> OppoDecodeEvent? {
        let fragmentType = packet.control & 3
        let messageStart = fragmentType <= 1 ? packet.startOffset : fragmentStartOffset
        if packet.control & 0x0040 != 0 {
            diagnostics.encryptedFrameCount += 1
            recordIssue(.encryptedFrame)
            recordFrame(packet, messageStart: messageStart, payload: nil, disposition: "IGNORED_ENCRYPTED_FRAME")
            // Like other single frames, this notification is independent of
            // an in-progress fragmented message. An unsupported fragment can
            // no longer be safely associated with that assembly.
            if fragmentType != 0 { clearFragments() }
            return nil
        }
        // Bit 3 is emitted by the APK and does not alter its parsing. Its
        // semantics are not labelled ACK. Other unknown controls are not used.
        guard packet.control & ~UInt16(0x000b) == 0 else {
            recordIssue(.unsupportedControl)
            recordFrame(packet, messageStart: messageStart, payload: nil, disposition: "IGNORED_UNSUPPORTED_CONTROL")
            if fragmentType != 0 { clearFragments() }
            return nil
        }

        do {
            guard let completed = try assemble(packet) else {
                let initialPayload = fragmentType == 1 ? Array(packet.payload.dropFirst()) : nil
                recordFrame(packet, messageStart: messageStart, payload: initialPayload,
                            disposition: fragmentType == 1 ? "FRAGMENT_START" : "FRAGMENT_CONTINUATION")
                return nil
            }
            if origin(of: completed.startOffset) == "PRE_QUERY" {
                diagnostics.preQueryMessageCount += 1
            } else {
                diagnostics.postQueryMessageCount += 1
            }
            do {
                let capabilities = try decodeCapabilities(completed.payload, control: completed.control,
                                                          frames: completed.frames, crcValidation: completed.crcValidation)
                if origin(of: completed.startOffset) == "PRE_QUERY" {
                    diagnostics.unsolicitedCapabilities = capabilities
                    recordFrame(packet, messageStart: completed.startOffset, payload: completed.payload,
                                disposition: "UNSOLICITED_CAPABILITIES")
                    return nil
                }
                recordFrame(packet, messageStart: completed.startOffset, payload: completed.payload,
                            disposition: "CAPABILITIES_AFTER_QUERY")
                return .capabilities(capabilities)
            } catch let issue as OppoDecodeError {
                recordIssue(issue)
                let disposition: String
                switch issue {
                case .unexpectedCommand:
                    diagnostics.ignoredCommandCount += 1
                    disposition = "IGNORED_OTHER_COMMAND"
                case .loopbackOrEcho:
                    diagnostics.echoCount += 1
                    disposition = "IGNORED_AMBIGUOUS_ECHO"
                default:
                    diagnostics.invalidCapabilityCount += 1
                    disposition = "INVALID_CAPABILITY_MESSAGE"
                }
                recordFrame(packet, messageStart: completed.startOffset, payload: completed.payload, disposition: disposition)
                return nil
            }
        } catch let issue as OppoDecodeError {
            recordIssue(issue)
            switch issue {
            case .unexpectedFragment: diagnostics.orphanFragmentCount += 1
            case .fragmentSequenceMismatch: diagnostics.sequenceGapCount += 1
            default: diagnostics.droppedMessageCount += 1
            }
            recordFrame(packet, messageStart: nil, payload: nil, disposition: "IGNORED_\(issue.rawValue)")
            clearFragments()
        } catch {
            recordIssue(.malformedProtobuf)
            diagnostics.droppedMessageCount += 1
            clearFragments()
        }
        return nil
    }

    /// Call when the probe expires or its notification stream ends. A partial
    /// header/frame or unfinished fragment sequence can never become success.
    mutating func finish() -> OppoDecodeEvent? {
        guard !failed, hasPendingData else { return nil }
        recordIssue(.incompleteFrame)
        diagnostics.incompleteMessageCount += 1
        diagnostics.discardedByteCount += buffer.count
        buffer.removeAll(keepingCapacity: false)
        bufferStartOffset = diagnostics.receivedByteCount
        clearFragments()
        return nil
    }

    private mutating func reject(_ error: OppoDecodeError) -> OppoDecodeEvent {
        recordIssue(error)
        buffer.removeAll(keepingCapacity: false)
        bufferStartOffset = diagnostics.receivedByteCount
        clearFragments()
        failed = true
        return .rejected(error)
    }

    private enum CRCByteOrder: Hashable {
        case littleEndian
        case bigEndian
    }

    private struct Packet {
        let startOffset: Int
        let byteCount: Int
        let bodyLength: Int
        let control: UInt16
        let payload: [UInt8]
        // nil means both CRC bytes are identical, so either ordering verifies.
        let crcOrder: CRCByteOrder?
    }

    private enum ScanResult {
        case incomplete
        case invalid(OppoDecodeError)
        case packet(Packet)
    }

    private static func crcValidation(for orders: Set<CRCByteOrder>) -> String {
        if orders.count == 2 { return "CRC16_MIXED_ENDIAN_COMPAT_VERIFIED" }
        if orders.contains(.bigEndian) { return "CRC16_BE_COMPAT_VERIFIED" }
        // Also valid when every trailer is endian-invariant. Such trailers do
        // not by themselves cause a fragmented message to be called mixed.
        return "CRC16_LE_VERIFIED"
    }

    private func scanPacket(at start: Int) -> ScanResult {
        guard buffer.count - start >= 2 else { return .incomplete }

        var bodyLength = Int(buffer[start + 1] & 0x7f)
        var lengthBytes = 1
        if buffer[start + 1] & 0x80 != 0 {
            guard buffer.count - start >= 3 else { return .incomplete }
            guard buffer[start + 2] & 0x80 == 0, buffer[start + 2] != 0 else {
                return .invalid(.invalidFrameLength)
            }
            bodyLength |= Int(buffer[start + 2]) << 7
            lengthBytes = 2
        }
        guard bodyLength >= 4 else { return .invalid(.invalidFrameLength) }
        guard bodyLength <= Self.maximumFrameBodyLength else { return .invalid(.oversizedFrame) }
        let bodyStart = start + 1 + lengthBytes
        let checksumIndex = bodyStart + bodyLength
        let end = checksumIndex + 2
        guard buffer.count >= end else { return .incomplete }

        let littleEndianCRC = UInt16(buffer[checksumIndex]) | (UInt16(buffer[checksumIndex + 1]) << 8)
        let bigEndianCRC = (UInt16(buffer[checksumIndex]) << 8) | UInt16(buffer[checksumIndex + 1])
        let calculatedCRC = OppoProtocol.crc16(bytes: buffer[start..<checksumIndex])
        guard calculatedCRC == littleEndianCRC || calculatedCRC == bigEndianCRC else {
            return .invalid(.checksumMismatch)
        }
        // The APK sender uses LE, while its receive path explicitly accepts
        // either trailer byte order. Preserve this compatibility and provenance.
        let crcOrder: CRCByteOrder? = littleEndianCRC == bigEndianCRC ? nil :
            (calculatedCRC == littleEndianCRC ? .littleEndian : .bigEndian)
        let control = UInt16(buffer[bodyStart]) | (UInt16(buffer[bodyStart + 1]) << 8)
        let payload = Array(buffer[(bodyStart + 2)..<checksumIndex])
        return .packet(Packet(startOffset: bufferStartOffset + start, byteCount: end - start,
                              bodyLength: bodyLength, control: control, payload: payload, crcOrder: crcOrder))
    }

    private mutating func assemble(_ packet: Packet) throws -> (payload: [UInt8], control: UInt16, frames: Int, crcValidation: String, startOffset: Int)? {
        let fragmentType = packet.control & 0x0003
        if fragmentType == 0 {
            // APK ps0.g.n processes a single frame independently while a
            // fragmented message is pending. Do not discard either one.
            let orders = Set(packet.crcOrder.map { [$0] } ?? [])
            return (packet.payload, packet.control, 1, Self.crcValidation(for: orders), packet.startOffset)
        }

        guard packet.payload.count >= 2 else { throw OppoDecodeError.invalidFrameLength }
        let sequence = packet.payload[0]
        let bytes = packet.payload.dropFirst()
        if fragmentType == 1 {
            if fragmentPayload != nil {
                diagnostics.replacedFragmentCount += 1
                recordIssue(.interleavedMessage)
            }
            fragmentPayload = Array(bytes)
            fragmentStartOffset = packet.startOffset
            lastFragmentSequence = sequence
            fragmentCount = 1
            fragmentCRCOrders = Set(packet.crcOrder.map { [$0] } ?? [])
            return nil
        }

        guard var assembled = fragmentPayload, let previous = lastFragmentSequence,
              let startOffset = fragmentStartOffset else {
            throw OppoDecodeError.unexpectedFragment
        }
        guard sequence == previous &+ 1 else { throw OppoDecodeError.fragmentSequenceMismatch }
        guard fragmentCount < Self.maximumFragmentCount,
              assembled.count <= Self.maximumMessageLength - bytes.count else {
            throw OppoDecodeError.oversizedMessage
        }
        assembled.append(contentsOf: bytes)
        fragmentCount += 1
        if let order = packet.crcOrder { fragmentCRCOrders.insert(order) }
        if fragmentType == 3 {
            let frames = fragmentCount
            let crcValidation = Self.crcValidation(for: fragmentCRCOrders)
            clearFragments()
            return (assembled, packet.control, frames, crcValidation, startOffset)
        }
        fragmentPayload = assembled
        lastFragmentSequence = sequence
        return nil
    }

    private func decodeCapabilities(_ payload: [UInt8], control: UInt16, frames: Int, crcValidation: String) throws -> OppoTransportCapabilities {
        guard payload.count >= 2 else { throw OppoDecodeError.invalidFrameLength }
        guard payload[0] == 1,
              payload[1] == 1 || payload[1] == 0x81 else {
            throw OppoDecodeError.unexpectedCommand(service: payload[0], command: payload[1])
        }
        let requestPayload = Array(OppoProtocol.transportConsultRequest.dropFirst(4).dropLast(2))
        guard payload != requestPayload else { throw OppoDecodeError.loopbackOrEcho }

        var reader = UInt32ProtobufReader(bytes: Array(payload.dropFirst(2)))
        var values: [Int: UInt32] = [:]
        while !reader.isAtEnd {
            let tag = try reader.readVarint()
            let field = tag >> 3
            guard field != 0, tag & 7 == 0 else { throw OppoDecodeError.malformedProtobuf }
            guard field <= 5 else { throw OppoDecodeError.unsupportedProtobufField(field) }
            guard values[Int(field)] == nil else { throw OppoDecodeError.duplicateProtobufField }
            values[Int(field)] = try reader.readVarint()
        }
        guard let version = values[1], let frameSize = values[2], let mtu = values[3] else {
            throw OppoDecodeError.missingRequiredFields
        }
        guard (1...5).contains(version) else { throw OppoDecodeError.unsupportedProtocolVersion(version) }
        // These are reporting bounds, not negotiated BLE limits. In particular,
        // do not reject a peer's 990-byte transport MTU just because CoreBluetooth
        // permits a smaller individual ATT write. No returned value is applied.
        guard (8...65_535).contains(frameSize) else {
            throw OppoDecodeError.invalidCapabilityValue(field: 2, value: frameSize)
        }
        guard (1...65_535).contains(mtu) else {
            throw OppoDecodeError.invalidCapabilityValue(field: 3, value: mtu)
        }
        return OppoTransportCapabilities(
            protocolVersion: Int(version), maxFrameSize: Int(frameSize), maxTransmissionUnit: Int(mtu),
            interval: Int(values[4] ?? 0), supportProtocol: values[5] ?? 0,
            commandID: Int(payload[1]), controlFlags: control, frameCount: frames,
            frameShape: frames == 1 ? "SINGLE_FRAME" : "REASSEMBLED_FRAGMENTS",
            crcValidation: crcValidation, encodedFieldNumbers: values.keys.sorted())
    }

    private struct UInt32ProtobufReader {
        let bytes: [UInt8]
        var offset = 0
        var isAtEnd: Bool { offset == bytes.count }

        mutating func readVarint() throws -> UInt32 {
            var value: UInt32 = 0
            for index in 0..<5 {
                guard offset < bytes.count else { throw OppoDecodeError.malformedProtobuf }
                let byte = bytes[offset]
                offset += 1
                if index == 4, byte & 0xf0 != 0 { throw OppoDecodeError.malformedProtobuf }
                value |= UInt32(byte & 0x7f) << (index * 7)
                if byte & 0x80 == 0 {
                    guard index == 0 || byte != 0 else { throw OppoDecodeError.malformedProtobuf }
                    return value
                }
            }
            throw OppoDecodeError.malformedProtobuf
        }
    }
}
