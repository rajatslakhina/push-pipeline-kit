import XCTest
@testable import PushPipelineKit

final class InterruptionClassifierTests: XCTestCase {

    // MARK: Hint parsing

    func testHintParsingCoversAllLevelsAndVariants() {
        XCTAssertEqual(InterruptionLevel.fromHint("passive"), .passive)
        XCTAssertEqual(InterruptionLevel.fromHint("active"), .active)
        XCTAssertEqual(InterruptionLevel.fromHint("time-sensitive"), .timeSensitive)
        XCTAssertEqual(InterruptionLevel.fromHint("TimeSensitive"), .timeSensitive)
        XCTAssertEqual(InterruptionLevel.fromHint("TIME_SENSITIVE"), .timeSensitive)
        XCTAssertEqual(InterruptionLevel.fromHint("critical"), .critical)
        XCTAssertEqual(InterruptionLevel.fromHint("CRITICAL"), .critical)
    }

    func testUnknownOrMissingHintDegradesToActiveNeverEscalates() {
        XCTAssertEqual(InterruptionLevel.fromHint(nil), .active)
        XCTAssertEqual(InterruptionLevel.fromHint(""), .active)
        XCTAssertEqual(InterruptionLevel.fromHint("urgent!!"), .active)
        XCTAssertEqual(InterruptionLevel.fromHint("crit1cal"), .active)
    }

    // MARK: Budget behavior

    func testTimeSensitiveWithinBudgetDelivers() async {
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 2, window: 300),
            clock: ManualClock()
        )
        let first = await classifier.classify(makeMessage(id: "m1", hint: "time-sensitive"))
        let second = await classifier.classify(makeMessage(id: "m2", hint: "time-sensitive"))
        XCTAssertEqual(first, .deliver(.timeSensitive))
        XCTAssertEqual(second, .deliver(.timeSensitive))
    }

    func testTimeSensitiveOverBudgetIsDemotedNotDropped() async {
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 1, window: 300),
            clock: ManualClock()
        )
        _ = await classifier.classify(makeMessage(id: "m1", hint: "time-sensitive"))
        let overflow = await classifier.classify(makeMessage(id: "m2", hint: "time-sensitive"))
        XCTAssertEqual(overflow, .demoted(from: .timeSensitive, to: .active))
        XCTAssertEqual(overflow.effectiveLevel, .active)
    }

    func testWindowExpiryRestoresBudget() async {
        let clock = ManualClock()
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 1, window: 60),
            clock: clock
        )
        _ = await classifier.classify(makeMessage(id: "m1", hint: "time-sensitive"))
        clock.advance(by: 61)
        let afterExpiry = await classifier.classify(makeMessage(id: "m2", hint: "time-sensitive"))
        XCTAssertEqual(afterExpiry, .deliver(.timeSensitive))
    }

    func testZeroBudgetDemotesEveryTimeSensitive() async {
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 0, window: 300),
            clock: ManualClock()
        )
        let outcome = await classifier.classify(makeMessage(id: "m1", hint: "time-sensitive"))
        XCTAssertEqual(outcome, .demoted(from: .timeSensitive, to: .active))
    }

    func testCriticalBypassesBudgetEvenUnderFlood() async {
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 0, window: 300),
            clock: ManualClock()
        )
        for index in 0..<10 {
            let outcome = await classifier.classify(makeMessage(id: "m\(index)", hint: "critical"))
            XCTAssertEqual(outcome, .deliver(.critical), "Critical must never be demoted")
        }
    }

    func testPassiveAndActiveNeverConsumeBudget() async {
        let clock = ManualClock()
        let classifier = InterruptionClassifier(
            policy: AttentionBudgetPolicy(timeSensitivePerWindow: 1, window: 300),
            clock: clock
        )
        for index in 0..<5 {
            _ = await classifier.classify(makeMessage(id: "p\(index)", hint: "passive"))
            _ = await classifier.classify(makeMessage(id: "a\(index)", hint: "active"))
        }
        let consumed = await classifier.consumedBudget()
        XCTAssertEqual(consumed, 0)
        let timeSensitive = await classifier.classify(makeMessage(id: "ts", hint: "time-sensitive"))
        XCTAssertEqual(timeSensitive, .deliver(.timeSensitive), "Budget untouched by cheaper levels")
    }
}
