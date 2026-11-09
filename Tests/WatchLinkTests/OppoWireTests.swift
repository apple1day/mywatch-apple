import XCTest
@testable import WatchLink

final class OppoWireTests: XCTestCase {
    // Independent fixtures use explicit APK field/framing layouts and Python
    // binascii.crc_hqx(data, 0). They are not captures from the user's watch.
    private let nonceProtobuf = "08ffffffffffffffffff01"
    private let nonceReply = "aa0f0000019808ffffffffffffffffff01793b"
    private let cipherParts = [
        "aa1001000001990a200001020304050607081a28",
        "aa10020001090a0b0c0d0e0f1011121314150fc7",
        "aa0d030002161718191a1b1c1d1e1fa079"
    ]

    func testEncoderMatchesCanonicalConsultAndUInt64NonceFixtures() throws {
        let consult = data("080510141814200a2803")
        XCTAssertEqual(try OppoProtocol.encode(service: 1, command: 1, protobuf: consult,
                                               maximumFrameLength: 20), [OppoProtocol.transportConsultRequest])
        XCTAssertEqual(try OppoProtocol.encode(service: 1, command: 24, protobuf: data(nonceProtobuf),
                                               maximumFrameLength: 20),
                       [data("aa0f0000011808ffffffffffffffffff01d891")])
    }

    func testEncoderMatchesIndependentTwentyByteFragmentFixtures() throws {
        let protobuf = Data([0x0a, 0x20]) + Data((0..<32).map { UInt8($0) })
        let encoded = try OppoProtocol.encode(service: 1, command: 0x99, protobuf: protobuf,
                                              maximumFrameLength: 20)
        XCTAssertEqual(encoded, cipherParts.map(data))
        XCTAssertEqual(encoded.map(\.count), [20, 20, 17])
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        var messages: [OppoDecodeEvent] = []
        for frame in encoded { messages += decoder.append(frame) }
        let message = try oneMessage(messages)
        XCTAssertEqual(message.serviceID, 1)
        XCTAssertEqual(message.commandID, 0x99)
        XCTAssertEqual(message.protobuf, protobuf)
        XCTAssertEqual(message.frameCount, 3)
        XCTAssertEqual(message.frameShape, "REASSEMBLED_FRAGMENTS")
        XCTAssertEqual(message.streamOffset, 0)
        XCTAssertEqual(message.crcValidation, "CRC16_LE_VERIFIED")
    }

    func testEncoderFragmentSequenceWrapMatchesIndependentFixtures() throws {
        let protobuf = Data([0x0a, 0x20]) + Data((0..<32).map { UInt8($0) })
        let expected = [
            "aa100100ff01990a200001020304050607088e94",
            "aa10020000090a0b0c0d0e0f1011121314156ebc",
            "aa0d030001161718191a1b1c1d1e1f5a01"
        ].map(data)
        XCTAssertEqual(try OppoProtocol.encode(service: 1, command: 0x99, protobuf: protobuf,
                                               maximumFrameLength: 20, startingSequence: 255), expected)
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(try oneMessage(decoder.append(expected.reduce(Data(), +))).protobuf, protobuf)
    }

    func testActualFrameLengthAndCanonicalVarintAtOneByteLengthBoundary() throws {
        // 122 bytes plus a bytes-field tag/length and SID/CID make 126 payload
        // bytes. A single frame needs a 128-byte body and therefore 133 total
        // bytes. A 132-byte budget cannot encode it in one canonical frame.
        let protobuf = try OppoProtobufWriter.encode([1: .bytes(Data(repeating: 0, count: 122))])
        for limit in [131, 132] {
            let frames = try OppoProtocol.encode(service: 1, command: 0x99, protobuf: protobuf,
                                                 maximumFrameLength: limit)
            XCTAssertEqual(frames.map(\.count), [131, 9])
            XCTAssertEqual(frames[0].prefix(5), data("aa7f010000"))
            XCTAssertTrue(frames.allSatisfy { $0.count <= limit })
            var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
            XCTAssertEqual(try oneMessage(decoder.append(frames.reduce(Data(), +))).protobuf, protobuf)
        }
        let single = try OppoProtocol.encode(service: 1, command: 0x99, protobuf: protobuf,
                                             maximumFrameLength: 133)
        XCTAssertEqual(single.map(\.count), [133])
        XCTAssertEqual(single[0].prefix(5), data("aa80010000"))
    }

    func testEncoderBoundsAreIndependentOfPeerReportedValues() throws {
        for invalid in [-1, 0, 7, 518, Int.max] {
            XCTAssertThrowsError(try OppoProtocol.encode(service: 1, command: 24, protobuf: Data(),
                                                        maximumFrameLength: invalid)) {
                XCTAssertEqual($0 as? OppoWireError, .invalidFrameLimit)
            }
        }
        let minimum = try OppoProtocol.encode(service: 1, command: 36, protobuf: Data(), maximumFrameLength: 8)
        XCTAssertEqual(minimum.map(\.count), [8])
        XCTAssertThrowsError(try OppoProtocol.encode(service: 1, command: 24,
                                                    protobuf: Data(repeating: 0, count: 1023), maximumFrameLength: 20)) {
            XCTAssertEqual($0 as? OppoWireError, .messageTooLarge)
        }
        XCTAssertThrowsError(try OppoProtocol.encode(service: 1, command: 24,
                                                    protobuf: Data(repeating: 0, count: 63), maximumFrameLength: 8)) {
            XCTAssertEqual($0 as? OppoWireError, .tooManyFragments)
        }
        let maximumProtobuf = try OppoProtobufWriter.encode([1: .bytes(Data(repeating: 0, count: 1019))])
        XCTAssertEqual(maximumProtobuf.count, 1022)
        let maximum = try OppoProtocol.encode(service: 1, command: 0x99, protobuf: maximumProtobuf,
                                              maximumFrameLength: 517)
        XCTAssertEqual(maximum.map(\.count), [517, 517, 13])
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(try oneMessage(decoder.append(maximum.reduce(Data(), +))).protobuf, maximumProtobuf)
    }

    func testDefaultDecoderStillIgnoresAuthenticationAndOptInPreservesConfigurationOnReset() throws {
        var legacy = OppoTransportDecoder()
        legacy.markQuerySubmitted()
        XCTAssertEqual(legacy.append(data(nonceReply)), [])
        XCTAssertEqual(legacy.diagnostics.ignoredCommandCount, 1)

        var enabled = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(try oneMessage(enabled.append(data(nonceReply))).protobuf, data(nonceProtobuf))
        XCTAssertEqual(enabled.diagnostics.preQueryMessageCount, 1)
        XCTAssertEqual(enabled.diagnostics.ignoredCommandCount, 0)
        enabled.reset()
        XCTAssertEqual(enabled.diagnostics, OppoDecoderDiagnostics())
        XCTAssertEqual(try oneMessage(enabled.append(data(nonceReply))).streamOffset, 0)
    }

    func testOnlySpecifiedServiceAndAuthenticationCommandsAreForwarded() throws {
        let commands: [UInt8] = [24, 25, 36, 37, 0x98, 0x99, 0xa4, 0xa5]
        for command in commands {
            let frames = try OppoProtocol.encode(service: 1, command: command, protobuf: data("0801"),
                                                 maximumFrameLength: 20)
            var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
            XCTAssertEqual(try oneMessage(decoder.append(frames[0])).commandID, command)
        }
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(decoder.append(data("aa0f0000029808ffffffffffffffffff01dcf4")), [])
        XCTAssertEqual(decoder.append(data("aa0f0000019a08ffffffffffffffffff01933d")), [])
        XCTAssertEqual(decoder.diagnostics.ignoredCommandCount, 2)
        // Empty framing is allowed here; mandatory protobuf fields are the
        // engine's schema decision, and are never fabricated by this layer.
        XCTAssertEqual(try oneMessage(decoder.append(data("aa04000001a47328"))).protobuf, Data())
    }

    func testAuthenticationMessagesRetainHeaderOffsetAcrossEveryNotificationSplit() throws {
        let bytes = data(nonceReply)
        for split in 1..<bytes.count {
            var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
            XCTAssertEqual(decoder.append(data("000102")), [])
            XCTAssertEqual(decoder.append(Data(bytes.prefix(split))), [])
            let boundary = decoder.diagnostics.receivedByteCount
            decoder.markQuerySubmitted()
            let message = try oneMessage(decoder.append(Data(bytes.dropFirst(split))))
            XCTAssertEqual(message.streamOffset, 3)
            XCTAssertLessThan(message.streamOffset, boundary)
            XCTAssertEqual(message.protobuf, data(nonceProtobuf))
            XCTAssertEqual(decoder.diagnostics.recentFrames.last?.messageOrigin, "PRE_QUERY")
        }
    }

    func testAuthenticationFirstFragmentOriginSurvivesLaterSubmissionBoundary() throws {
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(decoder.append(data(cipherParts[0])), [])
        let boundary = decoder.diagnostics.receivedByteCount
        decoder.markQuerySubmitted()
        let events = decoder.append(data(cipherParts[1] + cipherParts[2] + nonceReply))
        XCTAssertEqual(events.count, 2)
        let earlier = try oneMessage([events[0]])
        let later = try oneMessage([events[1]])
        XCTAssertEqual(earlier.streamOffset, 0)
        XCTAssertLessThan(earlier.streamOffset, boundary)
        XCTAssertEqual(later.streamOffset, 57)
        XCTAssertGreaterThanOrEqual(later.streamOffset, boundary)
        XCTAssertEqual(decoder.diagnostics.recentFrames[2].messageOrigin, "PRE_QUERY")
        XCTAssertEqual(decoder.diagnostics.recentFrames[3].messageOrigin, "POST_QUERY")
    }

    func testEncryptedUnsupportedOrCorruptedAuthenticationFramesNeverReachEngine() throws {
        var decoder = OppoTransportDecoder(emitAuthenticationMessages: true)
        XCTAssertEqual(decoder.append(data("aa0f4000019808ffffffffffffffffff017011")), [])
        XCTAssertEqual(decoder.append(data("aa0f1000019808ffffffffffffffffff01f375")), [])
        var corrupt = data(nonceReply)
        corrupt[corrupt.count - 1] ^= 1
        XCTAssertEqual(decoder.append(corrupt), [])
        XCTAssertEqual(decoder.diagnostics.encryptedFrameCount, 1)
        XCTAssertEqual(decoder.diagnostics.crcFailureCount, 1)
        XCTAssertEqual(try oneMessage(decoder.append(data(nonceReply))).protobuf, data(nonceProtobuf))
    }

    func testUInt64NoncesHaveNoSignedOrUInt32Truncation() throws {
        let reader = try OppoProtobufReader(data(nonceProtobuf), fields: [1: .varint])
        XCTAssertEqual(try reader.uint64(1), UInt64.max)
        XCTAssertEqual(try OppoProtobufWriter.encode([1: .varint(UInt64.max)]), data(nonceProtobuf))
        XCTAssertThrowsError(try reader.uint32(1)) {
            XCTAssertEqual($0 as? OppoProtobufError, .integerOutOfRange(field: 1))
        }
        let highBit = data("0880808080808080808001")
        XCTAssertEqual(try OppoProtobufReader(highBit, fields: [1: .varint]).uint64(1), UInt64(1) << 63)
        XCTAssertEqual(try OppoProtobufWriter.encode([1: .varint(0xfedc_ba98_7654_3210)]),
                       data("0890e4d0b287d3aeeefe01"))
        XCTAssertEqual(try OppoProtobufReader(data("08ffffffff0f"), fields: [1: .varint]).uint32(1), UInt32.max)
    }

    func testProtobufWriterUsesExactFieldNumbersLengthsAndExplicitDefaults() throws {
        let fields: [Int: OppoProtobufValue] = [5: .varint(1), 2: .bytes(data("aabb")), 1: .varint(2048)]
        XCTAssertEqual(try OppoProtobufWriter.encode(fields), data("0880101202aabb2801"))
        let defaults = try OppoProtobufWriter.encode([1: .varint(0), 2: .bytes(Data())])
        XCTAssertEqual(defaults, data("08001200"))
        let reader = try OppoProtobufReader(defaults, fields: [1: .varint, 2: .bytes, 3: .varint])
        XCTAssertEqual(reader.presentFieldNumbers, [1, 2])
        XCTAssertEqual(try reader.uint64(1), 0)
        XCTAssertEqual(try reader.bytes(2), Data())
        XCTAssertNil(try reader.uint64(3))
        XCTAssertEqual(try OppoProtobufWriter.encode([16: .varint(1)]), data("800101"))
    }

    func testKnownDuplicatesAndWireMismatchesAreRejected() {
        assertProtobufError("08010802", fields: [1: .varint], error: .duplicateField(1))
        assertProtobufError("0a000a00", fields: [1: .bytes], error: .duplicateField(1))
        assertProtobufError("0a0101", fields: [1: .varint], error: .wrongWireType(field: 1))
        assertProtobufError("0801", fields: [1: .bytes], error: .wrongWireType(field: 1))
        XCTAssertThrowsError(try OppoProtobufReader(data("0a00"), fields: [1: .bytes]).uint64(1)) {
            XCTAssertEqual($0 as? OppoProtobufError, .wrongWireType(field: 1))
        }
        XCTAssertThrowsError(try OppoProtobufReader(data("0801"), fields: [1: .varint]).bytes(1)) {
            XCTAssertEqual($0 as? OppoProtobufError, .wrongWireType(field: 1))
        }
    }

    func testUnknownOrdinaryFieldsAreSkippedWithoutWeakeningKnownFields() throws {
        // Unknown fixed64, fixed32, bytes and repeated varint fields surround
        // the required nonce. Only the declared field is retained by the reader.
        let bytes = data("1100010203040506071d000102032202aabb28012802082a")
        let reader = try OppoProtobufReader(bytes, fields: [1: .varint])
        XCTAssertEqual(try reader.uint64(1), 42)
        XCTAssertEqual(reader.presentFieldNumbers, [1])
        assertProtobufError("13", fields: [:], error: .unsupportedWireType(3))
        assertProtobufError("14", fields: [:], error: .unsupportedWireType(4))
        assertProtobufError("1600", fields: [:], error: .unsupportedWireType(6))
        assertProtobufError("1700", fields: [:], error: .unsupportedWireType(7))
    }

    func testMalformedVarintsLengthsAndTagsFailBeforeAllocatingOrReturningValues() {
        assertProtobufError("08", fields: [1: .varint], error: .truncatedInput)
        assertProtobufError("0880", fields: [1: .varint], error: .truncatedInput)
        assertProtobufError("08ffffffffffffffffff02", fields: [1: .varint], error: .varintOverflow)
        assertProtobufError("08ffffffffffffffffffff00", fields: [1: .varint], error: .varintOverflow)
        assertProtobufError("088000", fields: [1: .varint], error: .noncanonicalVarint)
        assertProtobufError("880001", fields: [1: .varint], error: .noncanonicalVarint)
        assertProtobufError("0a8000", fields: [1: .bytes], error: .noncanonicalVarint)
        assertProtobufError("0affffffffffffffffff01", fields: [1: .bytes], error: .truncatedInput)
        assertProtobufError("0a030102", fields: [1: .bytes], error: .truncatedInput)
        assertProtobufError("110001", fields: [:], error: .truncatedInput)
        assertProtobufError("1d0001", fields: [:], error: .truncatedInput)
        assertProtobufError("0001", fields: [:], error: .invalidFieldNumber)
        assertProtobufError("808080801001", fields: [:], error: .invalidFieldNumber)
    }

    func testProtobufReaderAndWriterEnforceMessageAndFieldBudgets() throws {
        XCTAssertThrowsError(try OppoProtobufReader(Data(repeating: 0, count: 1023), fields: [:])) {
            XCTAssertEqual($0 as? OppoProtobufError, .messageTooLarge)
        }
        XCTAssertThrowsError(try OppoProtobufWriter.encode([1: .bytes(Data(repeating: 0, count: 1020))])) {
            XCTAssertEqual($0 as? OppoProtobufError, .messageTooLarge)
        }
        let unknowns = Data((0..<65).flatMap { _ in [UInt8(0x10), 0] })
        XCTAssertThrowsError(try OppoProtobufReader(unknowns, fields: [:])) {
            XCTAssertEqual($0 as? OppoProtobufError, .tooManyFields)
        }
        let fields = Dictionary(uniqueKeysWithValues: (1...65).map { ($0, OppoProtobufValue.varint(0)) })
        XCTAssertThrowsError(try OppoProtobufWriter.encode(fields)) {
            XCTAssertEqual($0 as? OppoProtobufError, .tooManyFields)
        }
        for invalid in [-1, 0, 0x2000_0000] {
            XCTAssertThrowsError(try OppoProtobufWriter.encode([invalid: .varint(0)])) {
                XCTAssertEqual($0 as? OppoProtobufError, .invalidFieldNumber)
            }
            XCTAssertThrowsError(try OppoProtobufReader(Data(), fields: [invalid: .varint])) {
                XCTAssertEqual($0 as? OppoProtobufError, .invalidFieldNumber)
            }
        }
    }

    private func assertProtobufError(_ hex: String, fields: [Int: OppoProtobufWireType], error: OppoProtobufError,
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try OppoProtobufReader(data(hex), fields: fields), file: file, line: line) {
            XCTAssertEqual($0 as? OppoProtobufError, error, file: file, line: line)
        }
    }

    private func oneMessage(_ events: [OppoDecodeEvent]) throws -> OppoWireMessage {
        guard events.count == 1, case .message(let message) = events[0] else {
            XCTFail("Expected exactly one complete clear authentication message")
            throw NSError(domain: "OppoWireTests", code: 1)
        }
        return message
    }

    private func data(_ hex: String) -> Data {
        let characters = Array(hex)
        precondition(characters.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }
}
