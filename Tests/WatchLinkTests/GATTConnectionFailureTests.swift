import Foundation
import CoreBluetooth
import XCTest
@testable import WatchLink

final class GATTConnectionFailureTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_794_221_172)

    func testPublicSDKCode14IdentifiesPeerRemovedPairingInformation() {
        XCTAssertEqual(CBError.Code.peerRemovedPairingInformation.rawValue, 14)
        let failure = GATTConnectionFailure(stage: .connect,
            error: NSError(domain: CBErrorDomain, code: 14), occurredAt: observedAt)

        XCTAssertEqual(failure.domain, CBErrorDomain)
        XCTAssertEqual(failure.code, 14)
        XCTAssertEqual(failure.errorIdentifier, "PEER_REMOVED_PAIRING_INFORMATION")
        XCTAssertTrue(failure.requiresPairingRecovery)
        XCTAssertFalse(failure.recoverySteps.isEmpty)
        XCTAssertEqual(failure.occurredAt, observedAt)
    }

    func testATTAndLookalikeDomainsDoNotRecommendDeletingAPairing() {
        for domain in [CBATTErrorDomain, "AppErrorDomain", " " + CBErrorDomain,
                       CBErrorDomain + "\n", "\0" + CBErrorDomain] {
            let failure = GATTConnectionFailure(stage: .connect,
                error: NSError(domain: domain, code: 14), occurredAt: observedAt)

            XCTAssertFalse(failure.requiresPairingRecovery, domain)
            XCTAssertEqual(failure.errorIdentifier, "SYSTEM_ERROR", domain)
            XCTAssertTrue(failure.recoverySteps.isEmpty, domain)
            XCTAssertNotEqual(failure.domain, CBErrorDomain, domain)
        }
    }

    func testOtherCoreBluetoothCodesRemainGenericSystemFailures() {
        for code in [CBError.Code.connectionFailed.rawValue, CBError.Code.connectionTimeout.rawValue,
                     CBError.Code.encryptionTimedOut.rawValue, -1, 999] {
            let failure = GATTConnectionFailure(stage: .connect,
                error: NSError(domain: CBErrorDomain, code: code), occurredAt: observedAt)

            XCTAssertFalse(failure.requiresPairingRecovery)
            XCTAssertEqual(failure.errorIdentifier, "SYSTEM_ERROR")
            XCTAssertEqual(failure.code, code)
            XCTAssertTrue(failure.recoverySteps.isEmpty)
        }
    }

    func testMissingNSErrorDoesNotInventAnErrorCodeOrPairingFailure() throws {
        for stage in [GATTConnectionFailure.Stage.connect, .disconnection] {
            let failure = GATTConnectionFailure(stage: stage, error: nil, occurredAt: observedAt)
            XCTAssertNil(failure.domain)
            XCTAssertNil(failure.code)
            XCTAssertEqual(failure.errorIdentifier, "UNKNOWN")
            XCTAssertFalse(failure.requiresPairingRecovery)
            XCTAssertTrue(failure.recoverySteps.isEmpty)
            let object = try jsonObject(failure)
            XCTAssertNil(object["domain"])
            XCTAssertNil(object["code"])
            XCTAssertEqual(object["stage"] as? String, stage.rawValue)
            XCTAssertEqual(object["errorIdentifier"] as? String, "UNKNOWN")
        }
    }

    func testPrivateNSErrorUserInfoIsNeverIncludedInReportsOrGuidance() throws {
        let privateText = "PRIVATE-DEVICE-UUID-AND-PROOF"
        let error = NSError(domain: CBErrorDomain, code: 14, userInfo: [
            NSLocalizedDescriptionKey: privateText,
            NSLocalizedFailureReasonErrorKey: privateText,
            NSUnderlyingErrorKey: NSError(domain: privateText, code: 123),
            "rawPayload": Data(privateText.utf8)
        ])
        let failure = GATTConnectionFailure(stage: .connect, error: error, occurredAt: observedAt)
        let bytes = try JSONEncoder().encode(failure)
        let encodedText = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertFalse(encodedText.contains(privateText))
        XCTAssertFalse(failure.title.contains(privateText))
        XCTAssertFalse(failure.message.contains(privateText))
        XCTAssertFalse(failure.recoverySteps.joined().contains(privateText))
        XCTAssertEqual(Set(try jsonObject(failure).keys),
                       Set(["stage", "domain", "code", "occurredAt", "errorIdentifier"]))
    }

    func testRoundTripPreservesStageTimestampAndRecoveryClassification() throws {
        for stage in [GATTConnectionFailure.Stage.connect, .disconnection] {
            let original = GATTConnectionFailure(stage: stage,
                error: NSError(domain: CBErrorDomain, code: 14), occurredAt: observedAt)
            let bytes = try JSONEncoder().encode(original)
            let restored = try JSONDecoder().decode(GATTConnectionFailure.self, from: bytes)

            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.occurredAt, observedAt)
            XCTAssertEqual(restored.errorIdentifier, "PEER_REMOVED_PAIRING_INFORMATION")
            XCTAssertTrue(restored.requiresPairingRecovery)
            XCTAssertEqual(restored.recoverySteps, original.recoverySteps)
        }
    }

    func testUntrustedErrorDomainIsBoundedWithoutBecomingATrustedDomain() {
        let domain = "\0" + String(repeating: "x", count: 300) + "\n"
        let failure = GATTConnectionFailure(stage: .connect,
            error: NSError(domain: domain, code: 14), occurredAt: observedAt)
        let stored = failure.domain ?? ""

        XCTAssertEqual(stored.unicodeScalars.count, 161)
        XCTAssertTrue(stored.hasPrefix("\u{fffd}"))
        XCTAssertTrue(stored.hasSuffix("…"))
        XCTAssertNil(stored.rangeOfCharacter(from: .controlCharacters))
        XCTAssertFalse(failure.requiresPairingRecovery)
        XCTAssertEqual(failure.errorIdentifier, "SYSTEM_ERROR")
    }

    func testDecodedIdentifierCannotOverrideTheObservedErrorDomainAndCode() throws {
        for domain in [CBATTErrorDomain, CBErrorDomain] {
            let original = GATTConnectionFailure(stage: .connect,
                error: NSError(domain: domain, code: 14), occurredAt: observedAt)
            var object = try jsonObject(original)
            object["errorIdentifier"] = domain == CBErrorDomain
                ? "SYSTEM_ERROR" : "PEER_REMOVED_PAIRING_INFORMATION"
            let alteredBytes = try JSONSerialization.data(withJSONObject: object)
            let restored = try JSONDecoder().decode(GATTConnectionFailure.self, from: alteredBytes)

            XCTAssertEqual(restored, original)
            XCTAssertEqual(restored.requiresPairingRecovery, domain == CBErrorDomain)
            XCTAssertEqual(restored.errorIdentifier, original.errorIdentifier)
            XCTAssertEqual(restored.recoverySteps,
                           domain == CBErrorDomain ? GATTConnectionFailure.pairingRecoverySteps : [])
        }
    }

    private func jsonObject(_ failure: GATTConnectionFailure) throws -> [String: Any] {
        let bytes = try JSONEncoder().encode(failure)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    }
}
