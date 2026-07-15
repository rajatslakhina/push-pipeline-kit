import XCTest
@testable import PushPipelineKit

final class NotificationDeduplicatorTests: XCTestCase {

    func testFreshMessageIsAccepted() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        let verdict = await dedup.evaluate(makeMessage(id: "m1"))
        XCTAssertEqual(verdict, .fresh)
    }

    func testExactRedeliveryIsDuplicate() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1"))
        let verdict = await dedup.evaluate(makeMessage(id: "m1"))
        XCTAssertEqual(verdict, .duplicateDelivery)
    }

    func testWindowExpiryAllowsRedelivery() async {
        let clock = ManualClock()
        let dedup = NotificationDeduplicator(capacity: 16, window: 60, clock: clock)
        _ = await dedup.evaluate(makeMessage(id: "m1"))
        clock.advance(by: 61)
        let verdict = await dedup.evaluate(makeMessage(id: "m1"))
        XCTAssertEqual(verdict, .fresh, "Beyond the window the ID is forgotten")
    }

    func testCapacityEvictionForgetsOldestFirst() async {
        let dedup = NotificationDeduplicator(capacity: 2, window: 600, clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1"))
        _ = await dedup.evaluate(makeMessage(id: "m2"))
        _ = await dedup.evaluate(makeMessage(id: "m3")) // evicts m1
        let verdictOld = await dedup.evaluate(makeMessage(id: "m1"))
        XCTAssertEqual(verdictOld, .fresh, "Evicted ID is treated as new")
        let verdictRecent = await dedup.evaluate(makeMessage(id: "m3"))
        XCTAssertEqual(verdictRecent, .duplicateDelivery, "Recent ID still tracked")
    }

    func testCapacityClampsToAtLeastOne() async {
        let dedup = NotificationDeduplicator(capacity: -10, window: 600, clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1"))
        let verdict = await dedup.evaluate(makeMessage(id: "m1"))
        XCTAssertEqual(verdict, .duplicateDelivery, "Capacity 1 still deduplicates the last ID")
    }

    // MARK: Collapse-group ordering

    func testNewerSequenceIsFresh() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "order-42", sequence: 1))
        let verdict = await dedup.evaluate(makeMessage(id: "m2", collapseID: "order-42", sequence: 2))
        XCTAssertEqual(verdict, .fresh)
    }

    func testOlderSequenceIsStale() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "order-42", sequence: 5))
        let verdict = await dedup.evaluate(makeMessage(id: "m2", collapseID: "order-42", sequence: 3))
        XCTAssertEqual(verdict, .staleOutOfOrder(latestSeen: 5))
    }

    func testEqualSequenceUnderDifferentMessageIDIsLogicalDuplicate() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "order-42", sequence: 5))
        let verdict = await dedup.evaluate(makeMessage(id: "m2", collapseID: "order-42", sequence: 5))
        XCTAssertEqual(verdict, .duplicateDelivery)
    }

    func testStaleMessageOwnRedeliveryBecomesDuplicate() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "g", sequence: 9))
        _ = await dedup.evaluate(makeMessage(id: "m2", collapseID: "g", sequence: 1)) // stale
        let verdict = await dedup.evaluate(makeMessage(id: "m2", collapseID: "g", sequence: 1))
        XCTAssertEqual(verdict, .duplicateDelivery, "The stale message's own ID was remembered")
    }

    func testSequenceWithoutCollapseIDIsIgnoredForOrdering() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", sequence: 9))
        let verdict = await dedup.evaluate(makeMessage(id: "m2", sequence: 1))
        XCTAssertEqual(verdict, .fresh, "No collapse group means no ordering relation")
    }

    func testDifferentCollapseGroupsAreIndependent() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "a", sequence: 9))
        let verdict = await dedup.evaluate(makeMessage(id: "m2", collapseID: "b", sequence: 1))
        XCTAssertEqual(verdict, .fresh)
    }

    func testStatsCountersAreAccurate() async {
        let dedup = NotificationDeduplicator(clock: ManualClock())
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "g", sequence: 2))
        _ = await dedup.evaluate(makeMessage(id: "m1", collapseID: "g", sequence: 2)) // dup (ID)
        _ = await dedup.evaluate(makeMessage(id: "m2", collapseID: "g", sequence: 1)) // stale
        _ = await dedup.evaluate(makeMessage(id: "m3"))                                // fresh
        let stats = await dedup.currentStats()
        XCTAssertEqual(stats.freshAccepted, 2)
        XCTAssertEqual(stats.duplicatesDropped, 1)
        XCTAssertEqual(stats.staleDropped, 1)
        XCTAssertEqual(stats.trackedMessages, 3, "m1, m2, m3 all remembered")
        XCTAssertEqual(stats.trackedCollapseGroups, 1)
    }
}
