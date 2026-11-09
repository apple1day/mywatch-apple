import Foundation

/// Bounded recovery for the original 1/1 TransportConsult request. The owner
/// keeps one continuous decoder and the first query's receive-stream boundary,
/// and enforces one overall 45-second deadline across every attempt.
///
/// The APK retries this request up to three times at 2000 ms intervals. Here a
/// retry also waits for the preceding complete ATT acknowledgement. No identity
/// command can start while a queued or submitted query still needs its ACK.
final class VendorCapabilityQuery {
    static let maximumAttempts = 4
    static let retryDelayMilliseconds = 2000

    enum Action: Equatable {
        case send(attempt: Int)
        case scheduleRetry(attempt: Int, seconds: TimeInterval)
        case readyForAuthentication
    }

    /// Safe counters only. Payloads and transport capabilities remain in their
    /// existing models; neither is invented by a successful write or a timer.
    struct Snapshot: Codable, Equatable {
        var status = "NOT_STARTED"
        var queuedAttempts = 0
        var submittedAttempts = 0
        var acknowledgedAttempts = 0
        var maximumAttempts = VendorCapabilityQuery.maximumAttempts
        var retryDelayMilliseconds = VendorCapabilityQuery.retryDelayMilliseconds
        var hasCapabilities = false
        var currentAttempt: Int?
    }

    private enum State { case idle, running, ready, failed, cancelled }

    private struct Pending {
        let attempt: Int
        var submitted = false
        var acknowledged = false
        var retryExpired = false
    }

    private var state: State = .idle
    private var pending: Pending?
    private(set) var snapshot = Snapshot()

    /// Live admission to the identity stage, distinct from a preserved report.
    var isReadyForAuthentication: Bool { state == .ready }

    /// Even capabilities observed before this call do not skip the first write.
    func start() -> [Action] {
        guard state == .idle else { return [] }
        state = .running
        return enqueue(attempt: 1)
    }

    /// Called once, immediately before this attempt's first physical ATT write.
    /// Queue admission alone must never start the two-second retry interval.
    func didSubmit(attempt: Int) -> [Action] {
        guard state == .running, var current = pending,
              current.attempt == attempt, !current.submitted else { return [] }
        current.submitted = true
        pending = current
        snapshot.submittedAttempts += 1
        snapshot.status = "WAITING_FOR_WRITE_ACK"
        guard !snapshot.hasCapabilities, attempt < Self.maximumAttempts else { return [] }
        return [.scheduleRetry(attempt: attempt,
                               seconds: TimeInterval(Self.retryDelayMilliseconds) / 1000)]
    }

    /// One callback after all physical fragments of this logical query. The
    /// owner records the actual ATT error separately and terminates on failure.
    func writeCompleted(attempt: Int, succeeded: Bool) -> [Action] {
        guard state == .running, var current = pending,
              current.attempt == attempt, current.submitted,
              !current.acknowledged else { return [] }
        guard succeeded else {
            state = .failed
            pending = nil
            snapshot.status = "FAILED"
            return []
        }
        current.acknowledged = true
        pending = current
        snapshot.acknowledgedAttempts += 1
        if snapshot.hasCapabilities { return becomeReady() }
        if current.retryExpired, attempt < Self.maximumAttempts {
            return enqueue(attempt: attempt + 1)
        }
        snapshot.status = "WAITING_FOR_CAPABILITIES"
        return []
    }

    /// A timer is scoped to an actual submission. Expiration while its ATT
    /// callback is pending only records intent; it cannot submit another write.
    func retryTimerFired(attempt: Int) -> [Action] {
        guard state == .running, !snapshot.hasCapabilities,
              var current = pending, current.attempt == attempt,
              current.submitted, !current.retryExpired,
              attempt < Self.maximumAttempts else { return [] }
        current.retryExpired = true
        pending = current
        guard current.acknowledged else { return [] }
        return enqueue(attempt: attempt + 1)
    }

    /// Call only for a fully validated capability message, including a valid
    /// pre-query observation. The owner still validates conflicting parameters.
    func capabilitiesAvailable() -> [Action] {
        guard state == .idle || state == .running else { return [] }
        snapshot.hasCapabilities = true
        // A queued retry remains a real pending command: a capability arriving
        // between queue admission and its first write cannot bypass that ACK.
        guard state == .running, pending?.acknowledged == true else { return [] }
        return becomeReady()
    }

    /// Cancellation is terminal. Preserve successful/failure results and all
    /// observed counters; late callbacks cannot start a fresh attempt.
    func cancel() {
        if state == .ready {
            // Preserve the completed observation while revoking live admission.
            state = .cancelled
            pending = nil
            return
        }
        guard state == .idle || state == .running else { return }
        state = .cancelled
        pending = nil
        snapshot.status = "INTERRUPTED"
    }

    private func enqueue(attempt: Int) -> [Action] {
        pending = Pending(attempt: attempt)
        snapshot.currentAttempt = attempt
        snapshot.queuedAttempts += 1
        snapshot.status = "QUERY_QUEUED"
        return [.send(attempt: attempt)]
    }

    private func becomeReady() -> [Action] {
        state = .ready
        pending = nil
        snapshot.status = "READY_FOR_AUTHENTICATION"
        return [.readyForAuthentication]
    }
}
