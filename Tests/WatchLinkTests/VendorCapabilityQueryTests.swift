import Foundation
import XCTest
@testable import WatchLink

final class VendorCapabilityQueryTests: XCTestCase {
    func testFirstQueryIsMandatoryEvenWithValidatedPreQueryCapabilities() {
        let query = VendorCapabilityQuery()
        XCTAssertEqual(query.capabilitiesAvailable(), [])
        XCTAssertEqual(query.snapshot.status, "NOT_STARTED")
        XCTAssertFalse(query.isReadyForAuthentication)
        XCTAssertEqual(query.start(), [.send(attempt: 1)])
        XCTAssertEqual(query.start(), [])
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [])
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 0)
        XCTAssertEqual(query.didSubmit(attempt: 1), [])
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [.readyForAuthentication])
        XCTAssertTrue(query.isReadyForAuthentication)
        XCTAssertEqual(query.snapshot.queuedAttempts, 1)
        XCTAssertEqual(query.snapshot.submittedAttempts, 1)
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 1)
    }

    func testRetryTimerStartsOnlyAtActualSubmissionAndCannotRestart() {
        let query = VendorCapabilityQuery()
        XCTAssertEqual(query.start(), [.send(attempt: 1)])
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
        XCTAssertEqual(query.didSubmit(attempt: 2), [])
        XCTAssertEqual(query.snapshot.submittedAttempts, 0)
        XCTAssertEqual(query.didSubmit(attempt: 1), [.scheduleRetry(attempt: 1, seconds: 2)])
        XCTAssertEqual(query.didSubmit(attempt: 1), [])
        XCTAssertEqual(query.snapshot.submittedAttempts, 1)
        XCTAssertEqual(query.snapshot.status, "WAITING_FOR_WRITE_ACK")
    }

    func testTimerBeforeACKOnlyQueuesRetryAfterCompleteWriteSuccess() {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
        XCTAssertEqual(query.snapshot.queuedAttempts, 1)
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [.send(attempt: 2)])
        XCTAssertEqual(query.snapshot.queuedAttempts, 2)
        XCTAssertEqual(query.snapshot.submittedAttempts, 1)
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 1)
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [])
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
    }

    func testACKBeforeTimerWaitsForIntervalRatherThanImmediatelyRepeating() {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [])
        XCTAssertEqual(query.snapshot.status, "WAITING_FOR_CAPABILITIES")
        XCTAssertEqual(query.snapshot.queuedAttempts, 1)
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [.send(attempt: 2)])
        XCTAssertEqual(query.snapshot.currentAttempt, 2)
    }

    func testCapabilitiesBeforeACKSuppressRetryButStillWaitForACK() {
        for timerExpired in [false, true] {
            let query = VendorCapabilityQuery()
            _ = query.start()
            _ = query.didSubmit(attempt: 1)
            if timerExpired { XCTAssertEqual(query.retryTimerFired(attempt: 1), []) }
            XCTAssertEqual(query.capabilitiesAvailable(), [])
            XCTAssertTrue(query.snapshot.hasCapabilities)
            XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
            XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [.readyForAuthentication])
            XCTAssertEqual(query.snapshot.queuedAttempts, 1)
        }
    }

    func testCapabilitiesAfterACKCompleteExactlyOnceAndInvalidatePendingTimer() {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        _ = query.writeCompleted(attempt: 1, succeeded: true)
        XCTAssertEqual(query.capabilitiesAvailable(), [.readyForAuthentication])
        XCTAssertTrue(query.isReadyForAuthentication)
        let result = query.snapshot
        XCTAssertEqual(query.capabilitiesAvailable(), [])
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
        XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: false), [])
        XCTAssertEqual(query.start(), [])
        query.cancel()
        XCTAssertFalse(query.isReadyForAuthentication)
        XCTAssertEqual(query.snapshot, result)
        XCTAssertEqual(result.status, "READY_FOR_AUTHENTICATION")
    }

    func testCapabilitiesDuringQueuedRetryCannotSkipItsSubmissionAndACK() {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        _ = query.writeCompleted(attempt: 1, succeeded: true)
        XCTAssertEqual(query.retryTimerFired(attempt: 1), [.send(attempt: 2)])
        XCTAssertEqual(query.capabilitiesAvailable(), [])
        XCTAssertEqual(query.writeCompleted(attempt: 2, succeeded: true), [])
        XCTAssertFalse(query.isReadyForAuthentication)
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 1)
        XCTAssertEqual(query.didSubmit(attempt: 2), [])
        XCTAssertEqual(query.retryTimerFired(attempt: 2), [])
        XCTAssertEqual(query.writeCompleted(attempt: 2, succeeded: true), [.readyForAuthentication])
        XCTAssertTrue(query.isReadyForAuthentication)
        XCTAssertEqual(query.snapshot.submittedAttempts, 2)
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 2)
    }

    func testFourQueriesAreBoundedAndWritesAloneNeverStartAuthentication() {
        let query = VendorCapabilityQuery()
        XCTAssertEqual(query.start(), [.send(attempt: 1)])
        for attempt in 1...4 {
            let expected: [VendorCapabilityQuery.Action] = attempt < 4
                ? [.scheduleRetry(attempt: attempt, seconds: 2)] : []
            XCTAssertEqual(query.didSubmit(attempt: attempt), expected)
            XCTAssertEqual(query.writeCompleted(attempt: attempt, succeeded: true), [])
            if attempt < 4 {
                XCTAssertEqual(query.retryTimerFired(attempt: attempt), [.send(attempt: attempt + 1)])
            }
        }
        XCTAssertEqual(query.snapshot.maximumAttempts, 4)
        XCTAssertEqual(query.snapshot.retryDelayMilliseconds, 2000)
        XCTAssertEqual(query.snapshot.queuedAttempts, 4)
        XCTAssertEqual(query.snapshot.submittedAttempts, 4)
        XCTAssertEqual(query.snapshot.acknowledgedAttempts, 4)
        XCTAssertFalse(query.snapshot.hasCapabilities)
        XCTAssertFalse(query.isReadyForAuthentication)
        XCTAssertEqual(query.snapshot.status, "WAITING_FOR_CAPABILITIES")
        for attempt in 0...5 {
            XCTAssertEqual(query.retryTimerFired(attempt: attempt), [])
            XCTAssertEqual(query.didSubmit(attempt: attempt), [])
            XCTAssertEqual(query.writeCompleted(attempt: attempt, succeeded: true), [])
        }
        // The owner still owns its overall deadline; a valid later capability
        // inside that window can complete the fourth acknowledged attempt.
        XCTAssertEqual(query.capabilitiesAvailable(), [.readyForAuthentication])
    }

    func testFailedATTAfterEarlyCapabilitiesOrTimerCannotBeRevived() {
        for earlyCapabilities in [false, true] {
            let query = VendorCapabilityQuery()
            _ = query.start()
            _ = query.didSubmit(attempt: 1)
            _ = query.retryTimerFired(attempt: 1)
            if earlyCapabilities { _ = query.capabilitiesAvailable() }
            XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: false), [])
            XCTAssertEqual(query.snapshot.status, "FAILED")
            XCTAssertFalse(query.isReadyForAuthentication)
            XCTAssertEqual(query.snapshot.acknowledgedAttempts, 0)
            let failed = query.snapshot
            XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [])
            XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
            XCTAssertEqual(query.capabilitiesAvailable(), [])
            XCTAssertEqual(query.start(), [])
            query.cancel()
            XCTAssertFalse(query.isReadyForAuthentication)
            XCTAssertEqual(query.snapshot, failed)
        }
    }

    func testStaleAttemptCallbacksCannotAdvanceOrFailTheCurrentQuery() {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        _ = query.writeCompleted(attempt: 1, succeeded: true)
        _ = query.retryTimerFired(attempt: 1)
        _ = query.didSubmit(attempt: 2)
        let before = query.snapshot
        for attempt in [-1, 0, 1, 3, 99] {
            XCTAssertEqual(query.didSubmit(attempt: attempt), [])
            XCTAssertEqual(query.retryTimerFired(attempt: attempt), [])
            XCTAssertEqual(query.writeCompleted(attempt: attempt, succeeded: false), [])
            XCTAssertEqual(query.writeCompleted(attempt: attempt, succeeded: true), [])
        }
        XCTAssertEqual(query.snapshot, before)
        XCTAssertEqual(query.capabilitiesAvailable(), [])
        XCTAssertEqual(query.writeCompleted(attempt: 2, succeeded: true), [.readyForAuthentication])
    }

    func testCancellationBeforeStartDuringQueueOrAwaitingReplyIsTerminal() {
        for step in 0...3 {
            let query = VendorCapabilityQuery()
            if step >= 1 { _ = query.start() }
            if step >= 2 { _ = query.didSubmit(attempt: 1) }
            if step >= 3 { _ = query.writeCompleted(attempt: 1, succeeded: true) }
            query.cancel()
            let cancelled = query.snapshot
            XCTAssertEqual(cancelled.status, "INTERRUPTED")
            XCTAssertEqual(query.start(), [])
            XCTAssertEqual(query.didSubmit(attempt: 1), [])
            XCTAssertEqual(query.retryTimerFired(attempt: 1), [])
            XCTAssertEqual(query.writeCompleted(attempt: 1, succeeded: true), [])
            XCTAssertEqual(query.capabilitiesAvailable(), [])
            query.cancel()
            XCTAssertEqual(query.snapshot, cancelled)
        }
    }

    func testSnapshotRoundTripContainsOnlyBoundedRecoveryMetadata() throws {
        let query = VendorCapabilityQuery()
        _ = query.start()
        _ = query.didSubmit(attempt: 1)
        _ = query.writeCompleted(attempt: 1, succeeded: true)
        _ = query.retryTimerFired(attempt: 1)
        let encoded = try JSONEncoder().encode(query.snapshot)
        XCTAssertEqual(try JSONDecoder().decode(VendorCapabilityQuery.Snapshot.self, from: encoded), query.snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["status", "queuedAttempts", "submittedAttempts",
                                             "acknowledgedAttempts", "maximumAttempts", "retryDelayMilliseconds",
                                             "hasCapabilities", "currentAttempt"]))
        XCTAssertEqual(object["currentAttempt"] as? Int, 2)
        XCTAssertEqual(object["submittedAttempts"] as? Int, 1)
    }
}
