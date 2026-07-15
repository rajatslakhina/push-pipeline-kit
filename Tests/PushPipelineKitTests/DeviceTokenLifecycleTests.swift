import XCTest
@testable import PushPipelineKit

final class DeviceTokenLifecycleTests: XCTestCase {

    private func noJitterPolicy(maxAttempts: Int = 5) -> RegistrationRetryPolicy {
        RegistrationRetryPolicy(
            maxAttempts: maxAttempts,
            baseInterval: 1.0,
            maxInterval: 60.0,
            useFullJitter: false
        )
    }

    // MARK: Happy path

    func testTokenRegistersSuccessfully() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        let state = await lifecycle.state
        XCTAssertEqual(state, .registered(token: "token-A", generation: 1))
        let calls = await transport.registeredTokens
        XCTAssertEqual(calls, ["token-A"])
    }

    func testSameTokenWhileRegisteredIsIgnored() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        let count = await transport.callCount
        XCTAssertEqual(count, 1, "Re-delivered identical token must not re-register")
        let audit = await lifecycle.auditEvents()
        XCTAssertTrue(audit.contains(.duplicateTokenIgnored))
    }

    func testEmptyTokenIsIgnored() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("")
        await lifecycle.settle()

        let state = await lifecycle.state
        XCTAssertEqual(state, .unregistered)
        let count = await transport.callCount
        XCTAssertEqual(count, 0)
        let audit = await lifecycle.auditEvents()
        XCTAssertEqual(audit, [.emptyTokenIgnored])
    }

    // MARK: Retry behavior

    func testRetriesWithExponentialBackoffThenSucceeds() async {
        let transport = ScriptedTransport(script: [.fail, .fail, .succeed])
        let scheduler = RecordingScheduler()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(maxAttempts: 5),
            scheduler: scheduler
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        let state = await lifecycle.state
        XCTAssertEqual(state, .registered(token: "token-A", generation: 1))
        let count = await transport.callCount
        XCTAssertEqual(count, 3)
        // Backoff after attempt 1 = 1s, after attempt 2 = 2s.
        XCTAssertEqual(scheduler.waits, [1.0, 2.0])
    }

    func testParksAfterRetryBudgetExhausted() async {
        let transport = ScriptedTransport(script: [.fail, .fail, .fail])
        let scheduler = RecordingScheduler()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(maxAttempts: 3),
            scheduler: scheduler
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        let state = await lifecycle.state
        guard case .parked(let token, let generation, .retryBudgetExhausted) = state else {
            return XCTFail("Expected parked state, got \(state)")
        }
        XCTAssertEqual(token, "token-A")
        XCTAssertEqual(generation, 1)
        let count = await transport.callCount
        XCTAssertEqual(count, 3, "Exactly maxAttempts calls, then stop")
        XCTAssertEqual(scheduler.waits.count, 2, "No wait after the final attempt")
    }

    func testRetryNowEscapesParkedState() async {
        let transport = ScriptedTransport(script: [.fail, .fail])
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(maxAttempts: 2),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        guard case .parked = await lifecycle.state else {
            return XCTFail("Precondition: should be parked")
        }
        // Script is exhausted, so the retry succeeds.
        await lifecycle.retryNow()
        await lifecycle.settle()

        let state = await lifecycle.state
        XCTAssertEqual(state, .registered(token: "token-A", generation: 1))
    }

    func testRetryNowOutsideParkedIsNoOp() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.retryNow()
        await lifecycle.settle()
        let state = await lifecycle.state
        XCTAssertEqual(state, .unregistered)
        let count = await transport.callCount
        XCTAssertEqual(count, 0)
    }

    // MARK: The rotation race

    func testTokenRotationMidRegistrationDiscardsStaleCompletion() async {
        let transport = GatedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("token-OLD")
        await waitUntil("first registration in flight") {
            await transport.started == 1
        }
        // Token rotates while OLD's registration is still in flight.
        await lifecycle.tokenReceived("token-NEW")
        await waitUntil("second registration in flight") {
            await transport.started == 2
        }
        await transport.releaseAll()
        await lifecycle.settle()

        let state = await lifecycle.state
        XCTAssertEqual(
            state,
            .registered(token: "token-NEW", generation: 2),
            "The stale OLD completion must never overwrite the NEW registration"
        )
        await waitUntil("stale completion recorded") {
            let audit = await lifecycle.auditEvents()
            return audit.contains(.staleCompletionDiscarded(generation: 1, current: 2))
        }
    }

    // MARK: Server-side invalidation

    func testServerInvalidationRequestsFreshTokenAndObsoletesInFlight() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        await lifecycle.tokenReceived("token-A")
        await lifecycle.settle()

        let directive = await lifecycle.serverReportedInvalid()
        XCTAssertEqual(directive, .requestFreshToken)
        let midState = await lifecycle.state
        XCTAssertEqual(midState, .invalidated(generation: 2))

        // Fresh token arrives; new registration proceeds under generation 3.
        await lifecycle.tokenReceived("token-B")
        await lifecycle.settle()
        let state = await lifecycle.state
        XCTAssertEqual(state, .registered(token: "token-B", generation: 3))
    }

    // MARK: Policy math

    func testBackoffIntervalIsCappedAndFiniteForExtremeAttempts() {
        let policy = RegistrationRetryPolicy(
            maxAttempts: 5,
            baseInterval: 1.0,
            maxInterval: 60.0,
            useFullJitter: false
        )
        let extreme = policy.interval(afterAttempt: 10_000)
        XCTAssertTrue(extreme.isFinite)
        XCTAssertEqual(extreme, 60.0, "Capped at maxInterval")
        XCTAssertEqual(policy.interval(afterAttempt: 0), 1.0, "Attempt clamped to 1")
        XCTAssertEqual(policy.interval(afterAttempt: -5), 1.0, "Negative attempt clamped")
    }

    func testFullJitterScalesWithinBounds() {
        let policy = RegistrationRetryPolicy(
            maxAttempts: 5,
            baseInterval: 4.0,
            maxInterval: 60.0,
            useFullJitter: true,
            randomUnit: { 0.5 }
        )
        XCTAssertEqual(policy.interval(afterAttempt: 1), 2.0, "4 × 0.5 jitter")
        let zeroJitter = RegistrationRetryPolicy(
            maxAttempts: 5,
            baseInterval: 4.0,
            maxInterval: 60.0,
            useFullJitter: true,
            randomUnit: { 0.0 }
        )
        XCTAssertEqual(zeroJitter.interval(afterAttempt: 1), 0.0, "Jitter floor is 0")
    }

    func testAuditTrailIsBounded() async {
        let transport = ScriptedTransport()
        let lifecycle = DeviceTokenLifecycle(
            transport: transport,
            policy: noJitterPolicy(),
            scheduler: RecordingScheduler()
        )
        // Alternate distinct tokens so every event is recorded (identical
        // tokens would be ignored while registered).
        for index in 0..<150 {
            await lifecycle.tokenReceived("token-\(index)")
            await lifecycle.settle()
        }
        let audit = await lifecycle.auditEvents()
        XCTAssertLessThanOrEqual(audit.count, 100)
    }
}
