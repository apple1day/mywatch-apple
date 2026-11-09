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

/// A connection-scoped, fail-closed stream decoder. Reset when changing devices,
/// reconnecting or starting a new explicit probe. BLE notification boundaries
/// are unrelated to protocol frame boundaries.
struct OppoTransportDecoder {
    static let maximumFrameBodyLength = 512
    static let maximumMessageLength = 1024
    static let maximumBufferedLength = 4096
    static let maximumFragmentCount = 64

    private var buffer: [UInt8] = []
    private var fragmentPayload: [UInt8]?
    private var lastFragmentSequence: UInt8?
    private var fragmentCount = 0
    private var fragmentCRCOrders: Set<CRCByteOrder> = []
    private var failed = false

    var hasPendingData: Bool { !buffer.isEmpty || fragmentPayload != nil }

    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        fragmentPayload = nil
        lastFragmentSequence = nil
        fragmentCount = 0
        fragmentCRCOrders.removeAll()
        failed = false
    }

    mutating func append(_ data: Data) -> [OppoDecodeEvent] {
        guard !failed, !data.isEmpty else { return [] }
        guard data.count <= Self.maximumBufferedLength,
              buffer.count <= Self.maximumBufferedLength - data.count else {
            return [reject(.oversizedInput)]
        }
        buffer.append(contentsOf: data)
        var events: [OppoDecodeEvent] = []
        do {
            while let packet = try nextPacket() {
                if let completed = try assemble(packet) {
                    events.append(.capabilities(try decodeCapabilities(
                        completed.payload, control: completed.control, frames: completed.frames,
                        crcValidation: completed.crcValidation)))
                }
            }
        } catch let error as OppoDecodeError {
            events.append(reject(error))
        } catch {
            events.append(reject(.malformedProtobuf))
        }
        return events
    }

    /// Call when the probe expires or its notification stream ends. A partial
    /// header/frame or unfinished fragment sequence can never become success.
    mutating func finish() -> OppoDecodeEvent? {
        guard !failed, hasPendingData else { return nil }
        return reject(.incompleteFrame)
    }

    private mutating func reject(_ error: OppoDecodeError) -> OppoDecodeEvent {
        reset()
        failed = true
        return .rejected(error)
    }

    private enum CRCByteOrder: Hashable {
        case littleEndian
        case bigEndian
    }

    private struct Packet {
        let control: UInt16
        let payload: [UInt8]
        // nil means both CRC bytes are identical, so either ordering verifies.
        let crcOrder: CRCByteOrder?
    }

    private static func crcValidation(for orders: Set<CRCByteOrder>) -> String {
        if orders.count == 2 { return "CRC16_MIXED_ENDIAN_COMPAT_VERIFIED" }
        if orders.contains(.bigEndian) { return "CRC16_BE_COMPAT_VERIFIED" }
        // Also valid when every trailer is endian-invariant. Such trailers do
        // not by themselves cause a fragmented message to be called mixed.
        return "CRC16_LE_VERIFIED"
    }

    private mutating func nextPacket() throws -> Packet? {
        guard !buffer.isEmpty else { return nil }
        guard buffer[0] == 0xaa else { throw OppoDecodeError.invalidPreamble }
        guard buffer.count >= 2 else { return nil }

        var bodyLength = Int(buffer[1] & 0x7f)
        var lengthBytes = 1
        if buffer[1] & 0x80 != 0 {
            guard buffer.count >= 3 else { return nil }
            // The APK length field has at most two bytes. Reject noncanonical
            // encodings rather than scanning arbitrary bytes for a new header.
            guard buffer[2] & 0x80 == 0, buffer[2] != 0 else {
                throw OppoDecodeError.invalidFrameLength
            }
            bodyLength |= Int(buffer[2]) << 7
            lengthBytes = 2
        }
        guard bodyLength >= 4 else { throw OppoDecodeError.invalidFrameLength }
        guard bodyLength <= Self.maximumFrameBodyLength else { throw OppoDecodeError.oversizedFrame }
        let bodyStart = 1 + lengthBytes
        let checksumIndex = bodyStart + bodyLength
        let totalLength = checksumIndex + 2
        guard buffer.count >= totalLength else { return nil }

        let littleEndianCRC = UInt16(buffer[checksumIndex]) | (UInt16(buffer[checksumIndex + 1]) << 8)
        let bigEndianCRC = (UInt16(buffer[checksumIndex]) << 8) | UInt16(buffer[checksumIndex + 1])
        let calculatedCRC = OppoProtocol.crc16(bytes: buffer.prefix(checksumIndex))
        guard calculatedCRC == littleEndianCRC || calculatedCRC == bigEndianCRC else {
            throw OppoDecodeError.checksumMismatch
        }
        // The APK sender uses LE, while its receive path explicitly accepts
        // either trailer byte order. Preserve this compatibility and provenance.
        let crcOrder: CRCByteOrder? = littleEndianCRC == bigEndianCRC ? nil :
            (calculatedCRC == littleEndianCRC ? .littleEndian : .bigEndian)
        let control = UInt16(buffer[bodyStart]) | (UInt16(buffer[bodyStart + 1]) << 8)
        guard control & 0x0040 == 0 else { throw OppoDecodeError.encryptedFrame }
        // Low bits 0...3 select single/first/middle/last. The APK sender can
        // set bit 3 and its parser ignores it; do not invent an ACK meaning.
        guard control & ~UInt16(0x000b) == 0 else { throw OppoDecodeError.unsupportedControl }
        let payload = Array(buffer[(bodyStart + 2)..<checksumIndex])
        buffer.removeFirst(totalLength)
        return Packet(control: control, payload: payload, crcOrder: crcOrder)
    }

    private mutating func assemble(_ packet: Packet) throws -> (payload: [UInt8], control: UInt16, frames: Int, crcValidation: String)? {
        let fragmentType = packet.control & 0x0003
        if fragmentType == 0 {
            guard fragmentPayload == nil else { throw OppoDecodeError.interleavedMessage }
            let orders = Set(packet.crcOrder.map { [$0] } ?? [])
            return (packet.payload, packet.control, 1, Self.crcValidation(for: orders))
        }

        guard packet.payload.count >= 2 else { throw OppoDecodeError.invalidFrameLength }
        let sequence = packet.payload[0]
        let bytes = packet.payload.dropFirst()
        if fragmentType == 1 {
            guard fragmentPayload == nil else { throw OppoDecodeError.interleavedMessage }
            fragmentPayload = Array(bytes)
            lastFragmentSequence = sequence
            fragmentCount = 1
            fragmentCRCOrders = Set(packet.crcOrder.map { [$0] } ?? [])
            return nil
        }

        guard var assembled = fragmentPayload, let previous = lastFragmentSequence else {
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
            fragmentPayload = nil
            lastFragmentSequence = nil
            fragmentCount = 0
            fragmentCRCOrders.removeAll()
            return (assembled, packet.control, frames, crcValidation)
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
