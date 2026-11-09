import Foundation
import XCTest
@testable import WatchLink

final class OppoBusinessWireTests: XCTestCase {
    // Synthetic fixtures independently generated with Python cryptography
    // AES-256 CTR and binascii.crc_hqx(..., 0), not captured watch traffic.
    // Plaintext = SID11/CID7/StartSetting{1:1,2:2}, key=00...1f, IV=00...0f.
    private let envelope = "0a51690c5618f97196f02e553d02c3a692"
    private let encryptedSingle = "aa1340000a51690c5618f97196f02e553d02c3a692b01a"
    private let encryptedParts = [
        "aa104100000a51690c5618f97196f02e553d96bc",
        "aa0743000102c3a6921d19"
    ]

    func testClearBusinessRequestsMatchIndependentFramingFixtures() throws {
        let start = try OppoProtocol.encodePayload(hex("0b0708011002"), encrypted: false,
                                                    maximumFrameLength: 20)
        let query = try OppoProtocol.encodePayload(hex("0b0b"), encrypted: false,
                                                    maximumFrameLength: 20)
        XCTAssertEqual(start, [hex("aa0800000b0708011002b355")])
        XCTAssertEqual(query, [hex("aa0400000b0bbd83")])
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        let message = try clearMessage(decoder.append(start[0]))
        XCTAssertEqual(message.serviceID, 11)
        XCTAssertEqual(message.commandID, 7)
        XCTAssertEqual(message.protobuf, hex("08011002"))
        XCTAssertEqual(message.controlFlags, 0)
        XCTAssertEqual(try clearMessage(decoder.append(query[0])).protobuf, Data())
    }

    func testCiphertextIsSealedBeforeFragmentationAndEveryFrameCarriesEncryptionBit() throws {
        let single = try OppoProtocol.encodePayload(hex(envelope), encrypted: true, maximumFrameLength: 32)
        let fragmented = try OppoProtocol.encodePayload(hex(envelope), encrypted: true, maximumFrameLength: 20)
        XCTAssertEqual(single, [hex(encryptedSingle)])
        XCTAssertEqual(fragmented, encryptedParts.map(hex))
        XCTAssertEqual(fragmented.map(\.count), [20, 11])
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        let message = try encryptedMessage(decoder.append(fragmented.reduce(Data(), +)))
        XCTAssertEqual(message.payload, hex(envelope))
        XCTAssertEqual(message.controlFlags, 0x43)
        XCTAssertEqual(message.frameCount, 2)
        XCTAssertEqual(message.frameShape, "REASSEMBLED_FRAGMENTS")
        XCTAssertEqual(message.crcValidation, "CRC16_LE_VERIFIED")
    }

    func testEncryptedFragmentSequenceWrapUsesIndependentFixtures() throws {
        let expected = [
            "aa104100ff0a51690c5618f97196f02e553d0200",
            "aa0743000002c3a6924cb3"
        ].map(hex)
        XCTAssertEqual(try OppoProtocol.encodePayload(hex(envelope), encrypted: true,
                                                       maximumFrameLength: 20, startingSequence: 255), expected)
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertEqual(try encryptedMessage(decoder.append(expected.reduce(Data(), +))).payload, hex(envelope))
    }

    func testBusinessMessagesAreOptInAndResetPreservesConfiguration() throws {
        var legacy = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertTrue(legacy.append(hex(encryptedSingle)).isEmpty)
        XCTAssertTrue(legacy.append(hex("aa0400000b0bbd83")).isEmpty)
        XCTAssertEqual(legacy.diagnostics.encryptedFrameCount, 1)
        XCTAssertEqual(legacy.diagnostics.ignoredCommandCount, 1)
        XCTAssertEqual(legacy.diagnostics.preQueryMessageCount, 1)

        var enabled = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertEqual(try encryptedMessage(enabled.append(hex(encryptedSingle))).payload, hex(envelope))
        enabled.reset()
        XCTAssertEqual(enabled.diagnostics, OppoDecoderDiagnostics())
        XCTAssertEqual(try encryptedMessage(enabled.append(hex(encryptedSingle))).streamOffset, 0)
    }

    func testClearBusinessRoutingDoesNotWidenAuthenticationOrOtherServices() throws {
        let commands: [UInt8] = [7, 11, 12, 0x87, 0x8b, 0x8c]
        for command in commands {
            var decoder = OppoTransportDecoder(emitBusinessMessages: true)
            let frames = try OppoProtocol.encode(service: 11, command: command, protobuf: hex("0801"),
                                                 maximumFrameLength: 20)
            XCTAssertEqual(try clearMessage(decoder.append(frames[0])).commandID, command)
        }
        let otherRoutes: [(UInt8, UInt8)] = [(1, 7), (1, 24), (11, 6), (11, 9), (11, 14), (11, 21), (12, 11)]
        for (service, command) in otherRoutes {
            var decoder = OppoTransportDecoder(emitBusinessMessages: true)
            let frames = try OppoProtocol.encode(service: service, command: command, protobuf: hex("0801"),
                                                 maximumFrameLength: 20)
            XCTAssertTrue(decoder.append(frames[0]).isEmpty)
            XCTAssertEqual(decoder.diagnostics.ignoredCommandCount, 1)
        }
    }

    func testEncryptedRoutingBytesAreOpaqueEvenWhenTheyResembleCapabilities() throws {
        // Header bit0x40 owns interpretation, not a guess from encrypted bytes.
        let misleading = hex("0181080510141814200a2803")
        let frames = try OppoProtocol.encodePayload(misleading, encrypted: true, maximumFrameLength: 32)
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true, emitBusinessMessages: true)
        decoder.markQuerySubmitted()
        XCTAssertEqual(try encryptedMessage(decoder.append(frames[0])).payload, misleading)
        XCTAssertNil(decoder.diagnostics.unsolicitedCapabilities)
        XCTAssertEqual(decoder.diagnostics.invalidCapabilityCount, 0)
        XCTAssertTrue(decoder.diagnostics.recentFrames.allSatisfy { $0.serviceID == nil && $0.commandID == nil })
        let report = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoder.diagnostics)) as? [String: Any]
        let metadata = try XCTUnwrap((report?["recentFrames"] as? [[String: Any]])?.first)
        XCTAssertNil(metadata["payload"])
        XCTAssertNil(metadata["protobuf"])
        XCTAssertNil(metadata["serviceID"])
        XCTAssertNil(metadata["commandID"])
    }

    func testEveryNotificationSplitRetainsEncryptedMessageStartOffset() throws {
        let bytes = hex(encryptedParts.joined())
        for split in 1..<bytes.count {
            var decoder = OppoTransportDecoder(emitBusinessMessages: true)
            XCTAssertTrue(decoder.append(hex("000102")).isEmpty)
            XCTAssertTrue(decoder.append(Data(bytes.prefix(split))).isEmpty)
            let boundary = decoder.diagnostics.receivedByteCount
            decoder.markQuerySubmitted()
            let message = try encryptedMessage(decoder.append(Data(bytes.dropFirst(split))))
            XCTAssertEqual(message.streamOffset, 3)
            XCTAssertLessThan(message.streamOffset, boundary)
            XCTAssertEqual(message.payload, hex(envelope))
            XCTAssertEqual(decoder.diagnostics.recentFrames.last?.messageOrigin, "PRE_QUERY")
            XCTAssertEqual(decoder.diagnostics.encryptedFrameCount, 2)
            XCTAssertTrue(decoder.diagnostics.recentFrames.allSatisfy { $0.serviceID == nil && $0.commandID == nil })
        }
    }

    func testIndependentClearSingleFrameDoesNotDiscardEncryptedAssembly() throws {
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(decoder.append(hex(encryptedParts[0])).isEmpty)
        decoder.markQuerySubmitted()
        let events = decoder.append(hex("aa0400000b0bbd83" + encryptedParts[1]))
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(try clearMessage([events[0]]).streamOffset, 20)
        let encrypted = try encryptedMessage([events[1]])
        XCTAssertEqual(encrypted.streamOffset, 0)
        XCTAssertEqual(encrypted.payload, hex(envelope))
        XCTAssertEqual(decoder.diagnostics.recentFrames.last?.messageOrigin, "PRE_QUERY")
    }

    func testChangingEncryptionBitWithinFragmentsDropsTheWholeMessage() throws {
        for firstEncrypted in [false, true] {
            var decoder = OppoTransportDecoder(emitBusinessMessages: true)
            let first = replaceControl(hex(encryptedParts[0]), with: firstEncrypted ? 0x41 : 0x01)
            let last = replaceControl(hex(encryptedParts[1]), with: firstEncrypted ? 0x03 : 0x43)
            XCTAssertTrue(decoder.append(first + last).isEmpty)
            XCTAssertFalse(decoder.hasPendingData)
            XCTAssertEqual(decoder.diagnostics.lastIssue, "FRAGMENT_ENCRYPTION_MISMATCH")
            XCTAssertEqual(decoder.diagnostics.droppedMessageCount, 1)
            XCTAssertEqual(try encryptedMessage(decoder.append(hex(encryptedSingle))).payload, hex(envelope))
        }
    }

    func testCorruptCRCSequenceGapAndUnknownControlCannotProduceEncryptedMessage() throws {
        var corrupt = hex(encryptedParts[0])
        corrupt[corrupt.count - 1] ^= 1
        var crcDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(crcDecoder.append(corrupt + hex(encryptedParts[1])).isEmpty)
        XCTAssertEqual(crcDecoder.diagnostics.crcFailureCount, 1)
        XCTAssertEqual(crcDecoder.diagnostics.orphanFragmentCount, 1)
        XCTAssertEqual(try encryptedMessage(crcDecoder.append(hex(encryptedSingle))).payload, hex(envelope))

        var gapDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        let wrongSequence = framed(Data(hex(envelope).suffix(4)), control: 0x43, sequence: 2)
        XCTAssertTrue(gapDecoder.append(hex(encryptedParts[0]) + wrongSequence).isEmpty)
        XCTAssertEqual(gapDecoder.diagnostics.sequenceGapCount, 1)
        XCTAssertEqual(try encryptedMessage(gapDecoder.append(hex(encryptedSingle))).payload, hex(envelope))

        var controlDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(controlDecoder.append(replaceControl(hex(encryptedSingle), with: 0x50)).isEmpty)
        XCTAssertEqual(controlDecoder.diagnostics.lastIssue, "UNSUPPORTED_CONTROL_FLAGS")
        XCTAssertEqual(try encryptedMessage(controlDecoder.append(hex(encryptedSingle))).payload, hex(envelope))
    }

    func testEncryptedFramesPreserveMixedCRCByteOrderProvenance() throws {
        var bigEndianLast = hex(encryptedParts[1])
        bigEndianLast.swapAt(bigEndianLast.count - 2, bigEndianLast.count - 1)
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        let message = try encryptedMessage(decoder.append(hex(encryptedParts[0]) + bigEndianLast))
        XCTAssertEqual(message.payload, hex(envelope))
        XCTAssertEqual(message.crcValidation, "CRC16_MIXED_ENDIAN_COMPAT_VERIFIED")
    }

    func testBusinessCodecRetainsWholeMessageAndFragmentBudgets() throws {
        for invalid in [Data(), Data([0])] {
            XCTAssertThrowsError(try OppoProtocol.encodePayload(invalid, encrypted: true, maximumFrameLength: 20)) {
                XCTAssertEqual($0 as? OppoWireError, .invalidPayloadLength)
            }
        }
        XCTAssertThrowsError(try OppoProtocol.encodePayload(Data(repeating: 0, count: 1025), encrypted: true,
                                                            maximumFrameLength: 517)) {
            XCTAssertEqual($0 as? OppoWireError, .messageTooLarge)
        }
        XCTAssertThrowsError(try OppoProtocol.encodePayload(Data(repeating: 0, count: 65), encrypted: true,
                                                            maximumFrameLength: 8)) {
            XCTAssertEqual($0 as? OppoWireError, .tooManyFragments)
        }
        let maximum = Data(repeating: 0x35, count: 1024)
        let bounded = try OppoProtocol.encodePayload(maximum, encrypted: true, maximumFrameLength: 517)
        var boundedDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertEqual(try encryptedMessage(boundedDecoder.append(bounded.reduce(Data(), +))).payload, maximum)

        var oversized: Data = framed(Data(repeating: 0x35, count: 509), control: 0x41, sequence: 0)
        oversized.append(framed(Data(repeating: 0x35, count: 509), control: 0x42, sequence: 1))
        oversized.append(framed(Data(repeating: 0x35, count: 7), control: 0x43, sequence: 2))
        var oversizedDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(oversizedDecoder.append(oversized).isEmpty)
        XCTAssertEqual(oversizedDecoder.diagnostics.lastIssue, "OVERSIZED_MESSAGE")
        XCTAssertEqual(try encryptedMessage(oversizedDecoder.append(hex(encryptedSingle))).payload, hex(envelope))

        var excessiveFragments = Data()
        let fragmentPayload = Data([UInt8(0x35)])
        for index in 0..<65 {
            let control: UInt16
            switch index {
            case 0: control = 0x41
            case 64: control = 0x43
            default: control = 0x42
            }
            let frame: Data = framed(fragmentPayload, control: control, sequence: UInt8(index))
            excessiveFragments.append(frame)
        }
        var fragmentDecoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(fragmentDecoder.append(excessiveFragments).isEmpty)
        XCTAssertEqual(fragmentDecoder.diagnostics.lastIssue, "OVERSIZED_MESSAGE")
    }

    func testIncompleteEncryptedAssemblyCannotBecomeAResultAndResetClearsIt() throws {
        var decoder = OppoTransportDecoder(emitBusinessMessages: true)
        XCTAssertTrue(decoder.append(hex(encryptedParts[0])).isEmpty)
        XCTAssertTrue(decoder.hasPendingData)
        XCTAssertNil(decoder.finish())
        XCTAssertFalse(decoder.hasPendingData)
        XCTAssertEqual(decoder.diagnostics.incompleteMessageCount, 1)
        XCTAssertTrue(decoder.append(hex(encryptedParts[1])).isEmpty)
        decoder.reset()
        XCTAssertEqual(try encryptedMessage(decoder.append(hex(encryptedSingle))).payload, hex(envelope))
    }

    private func clearMessage(_ events: [OppoDecodeEvent]) throws -> OppoWireMessage {
        guard events.count == 1, case .message(let message) = events[0] else {
            XCTFail("Expected one complete clear business message")
            throw FixtureError.unexpectedEvent
        }
        return message
    }

    private func encryptedMessage(_ events: [OppoDecodeEvent]) throws -> OppoEncryptedMessage {
        guard events.count == 1, case .encryptedMessage(let message) = events[0] else {
            XCTFail("Expected one complete opaque encrypted message")
            throw FixtureError.unexpectedEvent
        }
        return message
    }

    // Fault-injection helper only. Encoding/CRC correctness above is checked
    // against independent fixed fixtures, not a second copy of the codec.
    private func framed(_ payload: Data, control: UInt16, sequence: UInt8? = nil) -> Data {
        var body = Data([UInt8(control & 0xff), UInt8(control >> 8)])
        if let sequence { body.append(sequence) }
        body.append(payload)
        let length = body.count < 128 ? Data([UInt8(body.count)])
            : Data([UInt8(body.count & 0x7f) | 0x80, UInt8(body.count >> 7)])
        var bytes = Data([UInt8(0xaa)])
        bytes.append(length)
        bytes.append(body)
        let checksum = OppoProtocol.crc16(bytes)
        bytes.append(contentsOf: [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
        return bytes
    }

    private func replaceControl(_ frame: Data, with control: UInt16) -> Data {
        // All fixtures used here have a one-byte body length.
        var prefix = Data(frame.dropLast(2))
        prefix[2] = UInt8(control & 0xff)
        prefix[3] = UInt8(control >> 8)
        let checksum = OppoProtocol.crc16(prefix)
        prefix.append(contentsOf: [UInt8(checksum & 0xff), UInt8(checksum >> 8)])
        return prefix
    }

    private func hex(_ value: String) -> Data {
        let characters = Array(value)
        precondition(characters.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }

    private enum FixtureError: Error { case unexpectedEvent }
}
