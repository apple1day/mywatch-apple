import XCTest
@testable import WatchLink

final class OppoProtocolTests: XCTestCase {
    // Static wire fixtures were calculated independently with Python's
    // binascii.crc_hqx(data, 0), not with the production codec or an encoder
    // copied into these tests. The request also matches the APK construction path.
    // None of the response fixtures is a recording from the user's watch.
    private let reply = "aa1000000181080510800418f401200a280399e6"
    private let first = "aa0901000001810805108029de"
    private let middle = "aa060200010418f4c5b2"
    private let last = "aa0803000201200a2803c0c6"
    private let otherCommand = "aa0e00000281080510141814200a2803199a"

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
            var decoder = queryDecoder()
            XCTAssertEqual(decoder.append(Data(bytes.prefix(split))), [])
            XCTAssertTrue(decoder.hasPendingData)
            XCTAssertEqual(decoder.append(Data(bytes.dropFirst(split))), [.capabilities(expected)])
            XCTAssertFalse(decoder.hasPendingData)
        }
        var oneByteDecoder = queryDecoder()
        var byteEvents: [OppoDecodeEvent] = []
        for byte in bytes { byteEvents += oneByteDecoder.append(Data([byte])) }
        XCTAssertEqual(byteEvents, [.capabilities(expected)])

        var coalesced = queryDecoder()
        XCTAssertEqual(coalesced.append(bytes + bytes), [.capabilities(expected), .capabilities(expected)])
    }

    func testVerifiedFragmentSequenceReassemblesBeforeParsing() throws {
        var decoder = queryDecoder()
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
        // A continuation's leading bytes are fragment data, not SID/CID.
        XCTAssertEqual(decoder.diagnostics.recentFrames[0].serviceID, 1)
        XCTAssertEqual(decoder.diagnostics.recentFrames[0].commandID, 129)
        XCTAssertNil(decoder.diagnostics.recentFrames[1].serviceID)
        XCTAssertNil(decoder.diagnostics.recentFrames[1].commandID)
        XCTAssertEqual(decoder.diagnostics.recentFrames[2].serviceID, 1)
        XCTAssertEqual(decoder.diagnostics.recentFrames[2].commandID, 129)

        var coalesced = queryDecoder()
        XCTAssertEqual(coalesced.append(data(first + middle + last)), events)
    }

    func testFragmentSequenceWrapOrphansAndGaps() throws {
        var wrapped = queryDecoder()
        XCTAssertEqual(wrapped.append(data("aa090100ff018108051080587b")), [])
        let wrappedReply = wrapped.append(data("aa0b0300000418f401200a2803cda6"))
        XCTAssertEqual(try singleCapability(wrappedReply).frameCount, 2)

        var missing = queryDecoder()
        XCTAssertEqual(missing.append(data(middle + last)), [])
        XCTAssertEqual(missing.diagnostics.orphanFragmentCount, 2)
        XCTAssertEqual(missing.diagnostics.lastIssue, "UNEXPECTED_FRAGMENT")
        XCTAssertTrue(missing.diagnostics.recentFrames.allSatisfy { $0.serviceID == nil && $0.commandID == nil })
        XCTAssertEqual(missing.append(data(reply)), [.capabilities(try capability(from: reply))])

        var wrong = queryDecoder()
        XCTAssertEqual(wrong.append(data(first)), [])
        XCTAssertEqual(wrong.append(data("aa0803000401200a2803214b")), [])
        XCTAssertEqual(wrong.diagnostics.sequenceGapCount, 1)
        XCTAssertEqual(wrong.diagnostics.lastIssue, "FRAGMENT_SEQUENCE_MISMATCH")
        XCTAssertFalse(wrong.hasPendingData)
        XCTAssertEqual(wrong.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testCorruptCRCIsNeverAcceptedAndFreshFrameRecovers() throws {
        var corrupt = data(reply)
        corrupt[corrupt.count - 1] ^= 1
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(corrupt), [])
        XCTAssertEqual(decoder.diagnostics.crcFailureCount, 1)
        XCTAssertEqual(decoder.diagnostics.lastIssue, "CRC_MISMATCH")
        XCTAssertEqual(decoder.diagnostics.validatedFrameCount, 0)
        XCTAssertFalse(decoder.hasPendingData)
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])

        var coalesced = queryDecoder()
        XCTAssertEqual(coalesced.append(data("000102") + corrupt + data(reply)),
                       [.capabilities(try capability(from: reply))])
        XCTAssertEqual(coalesced.diagnostics.crcFailureCount, 1)
        XCTAssertEqual(coalesced.diagnostics.discardedByteCount, 3 + corrupt.count)
        XCTAssertEqual(coalesced.diagnostics.recentFrames.first?.streamOffset, 3 + corrupt.count)
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
            var decoder = queryDecoder()
            XCTAssertEqual(decoder.append(data(incomplete)), [])
            XCTAssertTrue(decoder.hasPendingData)
            XCTAssertNil(decoder.finish())
            XCTAssertEqual(decoder.diagnostics.lastIssue, "INCOMPLETE_FRAME")
            XCTAssertEqual(decoder.diagnostics.incompleteMessageCount, 1)
            XCTAssertFalse(decoder.hasPendingData)
            XCTAssertNil(decoder.finish())
        }
        var empty = queryDecoder()
        XCTAssertEqual(empty.append(Data()), [])
        XCTAssertNil(empty.finish())
    }

    func testMalformedLengthsAndNoiseResynchronize() throws {
        try assertIgnored("0010", issue: .invalidPreamble)
        try assertIgnored("aa8180", issue: .invalidFrameLength)
        try assertIgnored("aa8e00", issue: .invalidFrameLength)
        try assertIgnored("aa03", issue: .invalidFrameLength)
        try assertIgnored("aa8104", issue: .oversizedFrame)
    }

    func testInputAndCumulativeBudgetsFailClosedUntilReset() throws {
        var oversized = queryDecoder()
        XCTAssertEqual(oversized.append(Data(repeating: 0xaa, count: OppoTransportDecoder.maximumBufferedLength + 1)),
                       [.rejected(.oversizedInput)])
        XCTAssertFalse(oversized.hasPendingData)
        XCTAssertEqual(oversized.append(data(reply)), [])

        var buffered = queryDecoder()
        XCTAssertEqual(buffered.append(data("aa")), [])
        XCTAssertEqual(buffered.append(Data(repeating: 0, count: OppoTransportDecoder.maximumBufferedLength)),
                       [.rejected(.oversizedInput)])

        var exhausted = queryDecoder()
        let chunk = Data(repeating: 0, count: OppoTransportDecoder.maximumBufferedLength)
        for _ in 0..<(OppoTransportDecoder.maximumReceivedByteCount / chunk.count) {
            XCTAssertEqual(exhausted.append(chunk), [])
        }
        XCTAssertEqual(exhausted.diagnostics.receivedByteCount, OppoTransportDecoder.maximumReceivedByteCount)
        XCTAssertEqual(exhausted.append(Data([0])), [.rejected(.oversizedInput)])
        XCTAssertEqual(exhausted.append(data(reply)), [])
        exhausted.reset()
        XCTAssertEqual(exhausted.diagnostics, OppoDecoderDiagnostics())
        exhausted.markQuerySubmitted()
        XCTAssertEqual(exhausted.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testReassembledMessageIsBoundedEvenWhenEachFrameIsValid() throws {
        // Three independent 512-byte-body golden frames, each with 509 data
        // bytes. Their CRCs come from binascii, not OppoProtocol.crc16.
        let padding = Data(repeating: 0, count: 509)
        let start = data("aa8004010000") + padding + data("26de")
        let continuation = data("aa8004020001") + padding + data("a60a")
        let end = data("aa8004030002") + padding + data("c56d")
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(start), [])
        XCTAssertEqual(decoder.append(continuation), [])
        XCTAssertEqual(decoder.append(end), [])
        XCTAssertEqual(decoder.diagnostics.lastIssue, "OVERSIZED_MESSAGE")
        XCTAssertEqual(decoder.diagnostics.droppedMessageCount, 1)
        XCTAssertFalse(decoder.hasPendingData)
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testEncryptedUnknownControlsAndWrongCommandsNeverBecomeCapabilities() throws {
        try assertIgnored("aa1040000181080510800418f401200a2803b16a", issue: .encryptedFrame)
        try assertIgnored("aa1010000181080510800418f401200a280393c5", issue: .unsupportedControl)
        try assertIgnored(otherCommand, issue: .unexpectedCommand(service: 2, command: 129))
        try assertIgnored("aa0e00000182080510141814200a28037ce7", issue: .unexpectedCommand(service: 1, command: 130))
        XCTAssertEqual(OppoDecodeError.unexpectedCommand(service: 2, command: 129).diagnosticMessage,
                       "UNEXPECTED_SERVICE_OR_COMMAND: sid=2, cid=129")
        XCTAssertEqual(try capability(from: "aa1008000181080510800418f401200a28031cf7").controlFlags, 8)

        var encrypted = queryDecoder()
        XCTAssertEqual(encrypted.append(data("aa1040000181080510800418f401200a2803b16a")), [])
        XCTAssertEqual(encrypted.diagnostics.encryptedFrameCount, 1)
        XCTAssertNil(encrypted.diagnostics.recentFrames.first?.serviceID)
        XCTAssertNil(encrypted.diagnostics.recentFrames.first?.commandID)
        XCTAssertEqual(encrypted.diagnostics.postQueryMessageCount, 0)
    }

    func testExactRequestEchoIsAmbiguousRatherThanConfirmedCapabilities() throws {
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(OppoProtocol.transportConsultRequest), [])
        XCTAssertEqual(decoder.diagnostics.echoCount, 1)
        XCTAssertEqual(decoder.diagnostics.lastIssue, "LOOPBACK_OR_ECHO")
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
        var fragmented = queryDecoder()
        XCTAssertEqual(fragmented.append(data("aa08010000010108051054bf")), [])
        XCTAssertEqual(fragmented.append(data("aa0a030001141814200a2803e60e")), [])
        XCTAssertEqual(fragmented.diagnostics.echoCount, 1)
        XCTAssertEqual(fragmented.diagnostics.lastIssue, "LOOPBACK_OR_ECHO")
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

    func testMissingOrUnsupportedCapabilitiesCarryBoundedReasons() throws {
        try assertIgnored("aa0c0000018108051014200a28033d5d", issue: .missingRequiredFields)
        try assertIgnored("aa0800000181101418144df1", issue: .missingRequiredFields)
        try assertIgnored("aa0a000001810806101418149913", issue: .unsupportedProtocolVersion(6))
        try assertIgnored("aa0a000001810800101418141cde", issue: .unsupportedProtocolVersion(0))
        try assertIgnored("aa0a00000181080510001814e862", issue: .invalidCapabilityValue(field: 2, value: 0))
        try assertIgnored("aa0a00000181080510141800feaf", issue: .invalidCapabilityValue(field: 3, value: 0))
        try assertIgnored("aa0c0000018108051080800418148564", issue: .invalidCapabilityValue(field: 2, value: 65_536))
        XCTAssertEqual(OppoDecodeError.unsupportedProtocolVersion(6).diagnosticMessage,
                       "UNSUPPORTED_PROTOCOL_VERSION: version=6")
    }

    func testMalformedUnknownAndDuplicateProtobufFieldsAreNeverAccepted() throws {
        let malformed = [
            "aa0b000001810a010510141814c09f", // wrong wire type
            "aa0a00000181080510141880763e", // truncated varint
            "aa0e00000181080510141880808080106290", // uint32 overflow
            "aa0b0000018108850010141814f50e", // noncanonical varint
            "aa060000018100014fdc" // field number zero
        ]
        for fixture in malformed { try assertIgnored(fixture, issue: .malformedProtobuf) }
        try assertIgnored("aa1200000181080510800418f401200a28030804b6cd", issue: .duplicateProtobufField)
        try assertIgnored("aa1200000181080510800418f401200a280330012f11", issue: .unsupportedProtobufField(6))
    }

    func testSingleFrameCanArriveDuringFragmentedMessage() throws {
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
        XCTAssertTrue(decoder.hasPendingData)
        XCTAssertEqual(decoder.diagnostics.replacedFragmentCount, 0)
        XCTAssertEqual(try singleCapability(decoder.append(data(middle + last))).frameCount, 3)
        XCTAssertFalse(decoder.hasPendingData)
    }

    func testIgnoredSingleFramesDoNotDiscardPendingPlaintextFragments() throws {
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        let encrypted = "aa1040000181080510800418f401200a2803b16a"
        let unsupportedControl = "aa1010000181080510800418f401200a280393c5"
        XCTAssertEqual(decoder.append(data(encrypted + unsupportedControl)), [])
        XCTAssertTrue(decoder.hasPendingData)
        XCTAssertEqual(decoder.diagnostics.encryptedFrameCount, 1)
        let ignoredFrames = Array(decoder.diagnostics.recentFrames.dropFirst())
        XCTAssertEqual(ignoredFrames.count, 2)
        XCTAssertTrue(ignoredFrames.allSatisfy { $0.serviceID == nil && $0.commandID == nil })
        XCTAssertEqual(try singleCapability(decoder.append(data(middle + last))).frameCount, 3)
        XCTAssertEqual(decoder.diagnostics.orphanFragmentCount, 0)
        XCTAssertFalse(decoder.hasPendingData)
    }

    func testNewFirstFragmentReplacesPendingMessageAndItsOrigin() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(data(first)), [])
        XCTAssertEqual(decoder.diagnostics.replacedFragmentCount, 1)
        XCTAssertEqual(decoder.diagnostics.lastIssue, "INTERLEAVED_MESSAGE")
        XCTAssertEqual(try singleCapability(decoder.append(data(middle + last))).frameCount, 3)
        XCTAssertNil(decoder.diagnostics.unsolicitedCapabilities)
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 0)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.recentFrames.last?.messageOrigin, "POST_QUERY")
    }

    func testCorruptedFragmentCannotCompleteAnEarlierMessage() throws {
        var corruptMiddle = data(middle)
        corruptMiddle[corruptMiddle.count - 1] ^= 1
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        XCTAssertEqual(decoder.append(corruptMiddle + data(last)), [])
        XCTAssertEqual(decoder.diagnostics.crcFailureCount, 1)
        XCTAssertEqual(decoder.diagnostics.orphanFragmentCount, 1)
        XCTAssertFalse(decoder.hasPendingData)
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testPreQueryCapabilityIsOnlyUnsolicitedDiagnosticEvidence() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(data(reply)), [])
        XCTAssertEqual(decoder.diagnostics.unsolicitedCapabilities, try capability(from: reply))
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 0)
        XCTAssertEqual(decoder.diagnostics.recentFrames.last?.disposition, "UNSOLICITED_CAPABILITIES")
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 1)
    }

    func testSyntheticTwentyNinePreQueryNotificationsThenOrphanAndFreshReply() throws {
        // Reproduces the report's timing/traffic shape only. The diagnostic
        // report contained counts, not packet bytes or command/file attribution.
        var decoder = OppoTransportDecoder()
        for _ in 0..<29 { XCTAssertEqual(decoder.append(data(otherCommand)), []) }
        XCTAssertEqual(decoder.diagnostics.ignoredCommandCount, 29)
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 29)
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(data(last)), [])
        XCTAssertEqual(decoder.diagnostics.orphanFragmentCount, 1)
        XCTAssertEqual(decoder.diagnostics.lastIssue, "UNEXPECTED_FRAGMENT")
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
        XCTAssertEqual(decoder.diagnostics.validatedFrameCount, 31)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 1)
        XCTAssertNil(decoder.diagnostics.unsolicitedCapabilities)
    }

    func testFragmentedMessageStartedBeforeQueryCannotSatisfyIt() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(data(middle + last)), [])
        XCTAssertEqual(decoder.diagnostics.unsolicitedCapabilities?.frameCount, 3)
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 0)
        XCTAssertEqual(decoder.diagnostics.recentFrames.last?.origin, "POST_QUERY")
        XCTAssertEqual(decoder.diagnostics.recentFrames.last?.messageOrigin, "PRE_QUERY")
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
    }

    func testHeaderStartedBeforeQueryRetainsItsOriginAcrossEveryByteBoundary() throws {
        let bytes = data(reply)
        for split in 1..<bytes.count {
            var decoder = OppoTransportDecoder()
            XCTAssertEqual(decoder.append(Data(bytes.prefix(split))), [])
            decoder.markQuerySubmitted()
            XCTAssertEqual(decoder.append(Data(bytes.dropFirst(split))), [])
            XCTAssertEqual(decoder.diagnostics.unsolicitedCapabilities, try capability(from: reply))
            XCTAssertEqual(decoder.diagnostics.recentFrames.first?.origin, "PRE_QUERY")
            XCTAssertEqual(decoder.diagnostics.recentFrames.first?.streamOffset, 0)
            XCTAssertEqual(decoder.append(bytes), [.capabilities(try capability(from: reply))])
        }
    }

    func testPreQueryTailAndPostQueryFrameCoalescedKeepSeparateOrigins() throws {
        let bytes = data(reply)
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(Data(bytes.prefix(1))), [])
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(Data(bytes.dropFirst(1)) + bytes),
                       [.capabilities(try capability(from: reply))])
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.recentFrames.map(\.origin), ["PRE_QUERY", "POST_QUERY"])
        XCTAssertEqual(decoder.diagnostics.recentFrames.map(\.streamOffset), [0, bytes.count])
    }

    func testRepeatedQueryMarkDoesNotMoveBoundaryOrFlushPartialFrame() throws {
        let bytes = data(reply)
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(Data(bytes.prefix(1))), [])
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(Data(bytes.dropFirst(1))), [.capabilities(try capability(from: reply))])
        XCTAssertNil(decoder.diagnostics.unsolicitedCapabilities)
    }

    func testUnsolicitedFragmentedMessageCanSurroundIndependentQueryReply() throws {
        var decoder = OppoTransportDecoder()
        XCTAssertEqual(decoder.append(data(first)), [])
        decoder.markQuerySubmitted()
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))])
        XCTAssertEqual(decoder.append(data(middle + last)), [])
        XCTAssertEqual(decoder.diagnostics.unsolicitedCapabilities?.frameCount, 3)
        XCTAssertEqual(decoder.diagnostics.preQueryMessageCount, 1)
        XCTAssertEqual(decoder.diagnostics.postQueryMessageCount, 1)
    }

    func testDiagnosticHistoryIsBoundedAndRoundTripsWithoutPayloadStorage() throws {
        var decoder = OppoTransportDecoder()
        for _ in 0..<40 { XCTAssertEqual(decoder.append(data(otherCommand)), []) }
        XCTAssertEqual(decoder.diagnostics.validatedFrameCount, 40)
        XCTAssertEqual(decoder.diagnostics.ignoredCommandCount, 40)
        XCTAssertEqual(decoder.diagnostics.recentFrames.count, 32)
        XCTAssertEqual(decoder.diagnostics.recentFrames.first?.streamOffset, 8 * data(otherCommand).count)
        let encoded = try JSONEncoder().encode(decoder.diagnostics)
        XCTAssertEqual(try JSONDecoder().decode(OppoDecoderDiagnostics.self, from: encoded), decoder.diagnostics)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let frames = try XCTUnwrap(object["recentFrames"] as? [[String: Any]])
        let headerKeys: Set<String> = ["streamOffset", "origin", "messageOrigin", "byteCount", "bodyLength",
                                       "controlFlags", "fragmentType", "fragmentSequence", "crcValidation",
                                       "serviceID", "commandID", "disposition"]
        XCTAssertTrue(frames.allSatisfy { Set($0.keys).isSubset(of: headerKeys) })
    }

    private func queryDecoder() -> OppoTransportDecoder {
        var decoder = OppoTransportDecoder()
        decoder.markQuerySubmitted()
        return decoder
    }

    private func assertIgnored(_ hex: String, issue: OppoDecodeError, file: StaticString = #filePath, line: UInt = #line) throws {
        var decoder = queryDecoder()
        XCTAssertEqual(decoder.append(data(hex)), [], file: file, line: line)
        XCTAssertEqual(decoder.diagnostics.lastIssue, issue.diagnosticMessage, file: file, line: line)
        XCTAssertEqual(decoder.append(data(reply)), [.capabilities(try capability(from: reply))], file: file, line: line)
    }

    private func events(_ hex: String) -> [OppoDecodeEvent] {
        var decoder = queryDecoder()
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
