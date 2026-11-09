import XCTest
@testable import WatchLink

final class OppoProtocolTests: XCTestCase {
    // Static wire fixtures were calculated independently with Python's
    // binascii.crc_hqx(data, 0), not with the production codec or an encoder
    // copied into these tests. The request additionally matches the APK trace.
    private let reply = "aa1000000181080510800418f401200a280399e6"
    private let first = "aa0901000001810805108029de"
    private let middle = "aa060200010418f4c5b2"
    private let last = "aa0803000201200a2803c0c6"

    func testCanonicalQueryAndIndependentCRCVector() {
        XCTAssertEqual(OppoProtocol.transportConsultRequest,
                       data("aa0e00000101080510141814200a28032c16"))
        XCTAssertEqual(OppoProtocol.transportConsultRequest.count, 18)
        XCTAssertEqual(OppoProtocol.crc16(Data("123456789".utf8)), 0x31c3)
        XCTAssertEqual(OppoProtocol.crc16(Data()), 0)
        XCTAssertEqual(OppoProtocol.crc16(OppoProtocol.transportConsultRequest.dropLast(2)), 0x162c)
    }

    func testCapabilityReplyRecordsValuesAndWireProvenance() throws {
        let observed = try capability(from: reply)
        XCTAssertEqual(observed.protocolVersion, 5)
        XCTAssertEqual(observed.maxFrameSize, 512)
        XCTAssertEqual(observed.maxTransmissionUnit, 244)
        XCTAssertEqual(observed.interval, 10)
        XCTAssertEqual(observed.supportProtocol, 3)
        XCTAssertEqual(observed.commandID, 0x81)
        XCTAssertEqual(observed.controlFlags, 0)
        XCTAssertEqual(observed.crcValidation, "CRC16_LE_VERIFIED")
        XCTAssertEqual(observed.frameShape, "SINGLE_FRAME")
        XCTAssertEqual(observed.frameCount, 1)
        XCTAssertEqual(observed.encodedFieldNumbers, [1, 2, 3, 4, 5])
    }

    func testEveryNotificationSplitAndCoalescedFrames() throws {
        let bytes = data(reply)
        let expected = try capability(from: reply)
        for split in 1..<bytes.count {
            var decoder = OppoTransportDecoder()
            XCTAssertEqual(decoder.append(Data(bytes.prefix(split))), [])
            XCTAssertTrue(decoder.hasPendingData)
            XCTAssertEqual(decoder.append(Data(bytes.dropFirst(split))), [.capabilities(expected)])
            XCTAssertFalse(decoder.hasPendingData)
        }
        var oneByteDecoder = OppoTransportDecoder()
        var byteEvents: [OppoDecodeEvent] = []
        for byte in bytes { byteEvents += oneByteDecoder.append(Data([byte])) }
        XCTAssertEqual(byteEvents, [.capabilities(expected)])

        var coalesced = OppoTransportDecoder()
        XCTAssertEqual(coalesced.append(bytes + bytes), [.capabilities(expected), .capabilities(expected)])
    }

    func testVerifiedFragmentSequenceReassemblesBeforeParsing() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        XCTAssertTrue(decoder.hasPendingData)
        XCTAssertEqual(decoder.append(data(middle)), [])
        let events = decoder.append(data(last))
        let observed = try singleCapability(events)
        XCTAssertEqual(observed.protocolVersion, 5)
        XCTAssertEqual(observed.maxFrameSize, 512)
        XCTAssertEqual(observed.maxTransmissionUnit, 244)
        XCTAssertEqual(observed.frameShape, "REASSEMBLED_FRAGMENTS")
        XCTAssertEqual(observed.frameCount, 3)
        XCTAssertEqual(observed.controlFlags, 3)
        XCTAssertFalse(decoder.hasPendingData)

        var coalesced = OppoTransportDecoder()
        XCTAssertEqual(coalesced.append(data(first + middle + last)), events)
    }

    func testFragmentSequenceWrapAndInvalidSequences() throws {
        var wrapped = OppoTransportDecoder()
        XCTAssertEqual(wrapped.append(data("aa090100ff018108051080587b")), [])
        let wrappedReply = wrapped.append(data("aa0b0300000418f401200a2803cda6"))
        XCTAssertEqual(try singleCapability(wrappedReply).frameCount, 2)

        var missing = OppoTransportDecoder()
        XCTAssertEqual(missing.append(data(last)), [.rejected(.unexpectedFragment)])
        var wrong = OppoTransportDecoder()
        XCTAssertEqual(wrong.append(data(first)), [])
        XCTAssertEqual(wrong.append(data("aa0803000401200a2803214b")),
                       [.rejected(.fragmentSequenceMismatch)])
        var interleaved = OppoTransportDecoder()
        XCTAssertEqual(interleaved.append(data(first)), [])
        XCTAssertEqual(interleaved.append(data(reply)), [.rejected(.interleavedMessage)])
    }

    func testCorruptCRCRejectsUntilExplicitReset() throws {
        var corrupt = data(reply)
        corrupt[corrupt.count - 1] ^= 1
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(corrupt), [.rejected(.checksumMismatch)])
        XCTAssertEqual(decoder.append(data(reply)), [])
        XCTAssertFalse(decoder.hasPendingData)
        decoder.reset()
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testAPKBigEndianCRCCompatibilityPreservesProvenanceAcrossFragments() throws {
        let bigEndian = try capability(from: "aa1000000181080510800418f401200a2803e699")
        XCTAssertEqual(bigEndian.crcValidation, "CRC16_BE_COMPAT_VERIFIED")
        XCTAssertEqual(bigEndian.protocolVersion, 5)
        XCTAssertEqual(bigEndian.maxFrameSize, 512)
        XCTAssertEqual(bigEndian.maxTransmissionUnit, 244)

        let firstBE = "aa09010000018108051080de29"
        let middleBE = "aa060200010418f4b2c5"
        let lastBE = "aa0803000201200a2803c6c0"
        let allBigEndian = try capability(from: firstBE + middleBE + lastBE)
        XCTAssertEqual(allBigEndian.crcValidation, "CRC16_BE_COMPAT_VERIFIED")
        XCTAssertEqual(allBigEndian.frameCount, 3)
        let mixed = try capability(from: first + middleBE + last)
        XCTAssertEqual(mixed.crcValidation, "CRC16_MIXED_ENDIAN_COMPAT_VERIFIED")
        XCTAssertEqual(mixed.frameCount, 3)
    }

    func testIncompleteFramesAndFragmentsCannotBecomeSuccess() {
        for incomplete in ["aa", "aa80", String(reply.dropLast(2)), first, first + middle] {
            var decoder = OppoTransportDecoder()
            XCTAssertEqual(decoder.append(data(incomplete)), [])
            XCTAssertTrue(decoder.hasPendingData)
            XCTAssertEqual(decoder.finish(), .rejected(.incompleteFrame))
            XCTAssertFalse(decoder.hasPendingData)
            XCTAssertNil(decoder.finish())
        }
        var empty = OppoTransportDecoder()
        XCTAssertEqual(empty.append(Data()), [])
        XCTAssertNil(empty.finish())
    }

    func testMalformedLengthsUnknownPreambleAndMemoryBounds() {
        XCTAssertEqual(events("0010"), [.rejected(.invalidPreamble)])
        XCTAssertEqual(events("aa8180"), [.rejected(.invalidFrameLength)])
        XCTAssertEqual(events("aa8e00"), [.rejected(.invalidFrameLength)])
        XCTAssertEqual(events("aa03"), [.rejected(.invalidFrameLength)])
        XCTAssertEqual(events("aa8104"), [.rejected(.oversizedFrame)])
        var oversized = OppoTransportDecoder()
        XCTAssertEqual(oversized.append(Data(repeating: 0xaa, count: OppoTransportDecoder.maximumBufferedLength + 1)),
                       [.rejected(.oversizedInput)])
        XCTAssertFalse(oversized.hasPendingData)
    }

    func testReassembledMessageIsBoundedEvenWhenEachFrameIsValid() {
        // Three independent 512-byte-body golden frames, each with 509 data
        // bytes. Their CRCs come from binascii, not OppoProtocol.crc16.
        let padding = Data(repeating: 0, count: 509)
        let start = data("aa8004010000") + padding + data("26de")
        let continuation = data("aa8004020001") + padding + data("a60a")
        let end = data("aa8004030002") + padding + data("c56d")
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(start), [])
        XCTAssertEqual(decoder.append(continuation), [])
        XCTAssertEqual(decoder.append(end), [.rejected(.oversizedMessage)])
        XCTAssertFalse(decoder.hasPendingData)
    }

    func testEncryptedUnknownControlsAndWrongCommandsNeverBecomeCapabilities() throws {
        XCTAssertEqual(events("aa1040000181080510800418f401200a2803b16a"), [.rejected(.encryptedFrame)])
        XCTAssertEqual(events("aa1010000181080510800418f401200a280393c5"), [.rejected(.unsupportedControl)])
        XCTAssertEqual(events("aa0e00000281080510141814200a2803199a"),
                       [.rejected(.unexpectedCommand(service: 2, command: 129))])
        XCTAssertEqual(events("aa0e00000182080510141814200a28037ce7"),
                       [.rejected(.unexpectedCommand(service: 1, command: 130))])
        XCTAssertEqual(OppoDecodeError.unexpectedCommand(service: 2, command: 129).diagnosticMessage,
                       "UNEXPECTED_SERVICE_OR_COMMAND: sid=2, cid=129")
        XCTAssertEqual(try capability(from: "aa1008000181080510800418f401200a28031cf7").controlFlags, 8)
    }

    func testExactRequestEchoIsAmbiguousRatherThanConfirmedCapabilities() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(OppoProtocol.transportConsultRequest), [.rejected(.loopbackOrEcho)])
        var fragmented = OppoTransportDecoder()
        XCTAssertEqual(fragmented.append(data("aa08010000010108051054bf")), [])
        XCTAssertEqual(fragmented.append(data("aa0a030001141814200a2803e60e")), [.rejected(.loopbackOrEcho)])
        // 0x81 is preserved as wire provenance, without calling it proof of
        // authentication. A distinct CID avoids matching the literal request.
        XCTAssertEqual(try capability(from: "aa0e00000181080510141814200a2803869f").commandID, 129)
    }

    func testCID1AndReportedMTUOverATTLimitRemainObservable() throws {
        let observed = try capability(from: "aa1000000101080310b42e18de072000280019a9")
        XCTAssertEqual(observed.commandID, 1)
        XCTAssertEqual(observed.protocolVersion, 3)
        XCTAssertEqual(observed.maxFrameSize, 5940)
        XCTAssertEqual(observed.maxTransmissionUnit, 990)
        XCTAssertEqual(observed.interval, 0)
        XCTAssertEqual(observed.supportProtocol, 0)
        XCTAssertEqual(observed.encodedFieldNumbers, [1, 2, 3, 4, 5])
    }

    func testProto3ZeroDefaultsAreDistinguishedFromExplicitWireValues() throws {
        let observed = try capability(from: "aa0a000001810801101418144d74")
        XCTAssertEqual(observed.interval, 0)
        XCTAssertEqual(observed.supportProtocol, 0)
        XCTAssertEqual(observed.encodedFieldNumbers, [1, 2, 3])
        let encoded = try JSONEncoder().encode(observed)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["encodedFieldNumbers"] as? [Int], [1, 2, 3])
        // Raw uint32 interval/support are reported only and never size a buffer
        // or schedule an operation from peer-controlled values.
        let maximum = try capability(from: "aa160000018108051014181420ffffffff0f28ffffffff0ff835")
        XCTAssertEqual(maximum.interval, Int(UInt32.max))
        XCTAssertEqual(maximum.supportProtocol, UInt32.max)
    }

    func testMissingOrUnsupportedCapabilitiesCarryBoundedReasons() {
        XCTAssertEqual(events("aa0c0000018108051014200a28033d5d"), [.rejected(.missingRequiredFields)])
        XCTAssertEqual(events("aa0800000181101418144df1"), [.rejected(.missingRequiredFields)])
        XCTAssertEqual(events("aa0a000001810806101418149913"), [.rejected(.unsupportedProtocolVersion(6))])
        XCTAssertEqual(events("aa0a000001810800101418141cde"), [.rejected(.unsupportedProtocolVersion(0))])
        XCTAssertEqual(events("aa0a00000181080510001814e862"), [.rejected(.invalidCapabilityValue(field: 2, value: 0))])
        XCTAssertEqual(events("aa0a00000181080510141800feaf"), [.rejected(.invalidCapabilityValue(field: 3, value: 0))])
        XCTAssertEqual(events("aa0c0000018108051080800418148564"), [.rejected(.invalidCapabilityValue(field: 2, value: 65_536))])
        XCTAssertEqual(OppoDecodeError.unsupportedProtocolVersion(6).diagnosticMessage,
                       "UNSUPPORTED_PROTOCOL_VERSION: version=6")
    }

    func testMalformedUnknownAndDuplicateProtobufFieldsAreRejected() {
        let malformed = [
            "aa0b000001810a010510141814c09f", // wrong wire type
            "aa0a00000181080510141880763e", // truncated varint
            "aa0e00000181080510141880808080106290", // uint32 overflow
            "aa0b0000018108850010141814f50e", // noncanonical varint
            "aa060000018100014fdc" // field number zero
        ]
        for fixture in malformed { XCTAssertEqual(events(fixture), [.rejected(.malformedProtobuf)]) }
        XCTAssertEqual(events("aa1200000181080510800418f401200a28030804b6cd"),
                       [.rejected(.duplicateProtobufField)])
        XCTAssertEqual(events("aa1200000181080510800418f401200a280330012f11"),
                       [.rejected(.unsupportedProtobufField(6))])
    }

    private func events(_ hex: String) -> [OppoDecodeEvent] {
        var decoder = OppoTransportDecoder()
        return decoder.append(data(hex))
    }

    private func capability(from hex: String) throws -> OppoTransportCapabilities {
        try singleCapability(events(hex))
    }

    private func singleCapability(_ events: [OppoDecodeEvent]) throws -> OppoTransportCapabilities {
        guard events.count == 1, case .capabilities(let value) = events[0] else {
            XCTFail("Expected exactly one validated capability observation")
            throw NSError(domain: "OppoProtocolTests", code: 1)
        }
        return value
    }

    private func data(_ hex: String) -> Data {
        let characters = Array(hex)
        precondition(characters.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: characters.count, by: 2).map {
            UInt8(String(characters[$0...($0 + 1)]), radix: 16)!
        })
    }
}
