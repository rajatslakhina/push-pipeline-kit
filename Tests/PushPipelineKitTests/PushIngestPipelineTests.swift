import XCTest
@testable import PushPipelineKit

final class PushIngestPipelineTests: XCTestCase {

    private struct Fixture {
        let pipeline: PushIngestPipeline
        let recorder: RouteRecorder
        let clock: ManualClock
    }

    private func makeFixture(
        timeSensitiveBudget: Int = 3,
        bufferLimit: Int = 8
    ) -> Fixture {
        let clock = ManualClock()
        let recorder = RouteRecorder()
        let orderResolver = ClosureRouteResolver { components in
            guard components.host == "orders",
                  let orderID = components.pathSegments.first else { return nil }
            return ResolvedRoute(identifier: "orderDetail", parameters: ["orderID": orderID])
        }
        let pipeline = PushIngestPipeline(
            deduplicator: NotificationDeduplicator(capacity: 128, window: 600, clock: clock),
            classifier: InterruptionClassifier(
                policy: AttentionBudgetPolicy(timeSensitivePerWindow: timeSensitiveBudget, window: 300),
                clock: clock
            ),
            router: DeepLinkRouter(
                resolvers: [orderResolver],
                fallbackRoute: ResolvedRoute(identifier: "home")
            ),
            dispatcher: RouteDispatcher(bufferLimit: bufferLimit) { recorder.append($0) }
        )
        return Fixture(pipeline: pipeline, recorder: recorder, clock: clock)
    }

    // MARK: End-to-end dispositions

    func testDuplicateBurstDeliversExactlyOnce() async {
        let fixture = makeFixture()
        var delivered = 0
        for _ in 0..<5 {
            let outcome = await fixture.pipeline.ingest(
                makeMessage(id: "same-id", collapseID: "g", sequence: 1, deepLink: "app://orders/9")
            )
            if case .delivered = outcome.disposition { delivered += 1 }
        }
        XCTAssertEqual(delivered, 1)
        let stats = await fixture.pipeline.currentStats()
        XCTAssertEqual(stats.ingested, 5)
        XCTAssertEqual(stats.delivered, 1)
        XCTAssertEqual(stats.duplicatesDropped, 4)
    }

    func testStaleUpdateIsDroppedAfterNewerOne() async {
        let fixture = makeFixture()
        _ = await fixture.pipeline.ingest(makeMessage(id: "m1", collapseID: "order-7", sequence: 4))
        let outcome = await fixture.pipeline.ingest(
            makeMessage(id: "m2", collapseID: "order-7", sequence: 2)
        )
        XCTAssertEqual(outcome.disposition, .droppedStale(latestSeen: 4))
        let stats = await fixture.pipeline.currentStats()
        XCTAssertEqual(stats.staleDropped, 1)
    }

    func testDuplicatesNeverConsumeAttentionBudget() async {
        let fixture = makeFixture(timeSensitiveBudget: 1)
        // First time-sensitive consumes the whole budget.
        _ = await fixture.pipeline.ingest(makeMessage(id: "t1", hint: "time-sensitive"))
        // Re-deliveries of t1 are dropped by dedup — they must not burn budget.
        for _ in 0..<3 {
            _ = await fixture.pipeline.ingest(makeMessage(id: "t1", hint: "time-sensitive"))
        }
        let stats = await fixture.pipeline.currentStats()
        XCTAssertEqual(stats.demoted, 0, "Duplicates were dropped before classification")
    }

    func testOverBudgetTimeSensitiveIsDeliveredDemoted() async {
        let fixture = makeFixture(timeSensitiveBudget: 1)
        _ = await fixture.pipeline.ingest(makeMessage(id: "t1", hint: "time-sensitive"))
        let overflow = await fixture.pipeline.ingest(makeMessage(id: "t2", hint: "time-sensitive"))
        guard case .delivered(let level, let wasDemoted, _) = overflow.disposition else {
            return XCTFail("Expected delivered, got \(overflow.disposition)")
        }
        XCTAssertEqual(level, .active)
        XCTAssertTrue(wasDemoted)
    }

    func testMalformedDeepLinkStillDeliversWithFallbackRoute() async {
        let fixture = makeFixture()
        let outcome = await fixture.pipeline.ingest(
            makeMessage(id: "m1", deepLink: "::::not a link::::")
        )
        guard case .delivered(_, _, let route) = outcome.disposition else {
            return XCTFail("Malformed link must not drop the notification")
        }
        XCTAssertEqual(
            route,
            .fallback(ResolvedRoute(identifier: "home"), reason: .malformedLink)
        )
    }

    // MARK: Tap dispatch and cold start

    func testColdStartTapIsBufferedThenReplayedOnReady() async {
        let fixture = makeFixture()
        let outcome = await fixture.pipeline.ingest(
            makeMessage(id: "m1", deepLink: "app://orders/1234")
        )
        guard case .delivered(_, _, let route) = outcome.disposition else {
            return XCTFail("Expected delivered")
        }
        // Simulated tap before the UI exists (cold start).
        let dispatch = await fixture.pipeline.open(route)
        XCTAssertEqual(dispatch, .buffered(depth: 1))
        XCTAssertTrue(fixture.recorder.routes.isEmpty)

        let replayed = await fixture.pipeline.markUIReady()
        XCTAssertEqual(replayed.map(\.identifier), ["orderDetail"])
        XCTAssertEqual(fixture.recorder.routes.map(\.identifier), ["orderDetail"])
    }

    func testWarmTapDispatchesImmediately() async {
        let fixture = makeFixture()
        _ = await fixture.pipeline.markUIReady()
        let outcome = await fixture.pipeline.ingest(
            makeMessage(id: "m1", deepLink: "app://orders/55")
        )
        guard case .delivered(_, _, let route) = outcome.disposition else {
            return XCTFail("Expected delivered")
        }
        let dispatch = await fixture.pipeline.open(route)
        XCTAssertEqual(dispatch, .delivered)
        XCTAssertEqual(
            fixture.recorder.routes,
            [ResolvedRoute(identifier: "orderDetail", parameters: ["orderID": "55"])]
        )
    }

    // MARK: Audit trail

    func testRecentOutcomesReflectProcessingOrderAndAreBounded() async {
        let fixture = makeFixture()
        for index in 0..<250 {
            _ = await fixture.pipeline.ingest(makeMessage(id: "m\(index)"))
        }
        let outcomes = await fixture.pipeline.recentOutcomes()
        XCTAssertEqual(outcomes.count, 200, "Bounded to the most recent 200")
        XCTAssertEqual(outcomes.first?.messageID, "m50", "Oldest retained entry")
        XCTAssertEqual(outcomes.last?.messageID, "m249", "Newest entry last")
    }
}
