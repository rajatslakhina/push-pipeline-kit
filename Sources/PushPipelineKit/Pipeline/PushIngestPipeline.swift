import Foundation

/// The pipeline's decision record for one ingested message.
public struct IngestOutcome: Sendable, Equatable {
    public enum Disposition: Sendable, Equatable {
        /// Presented to the user at `level`, with the route decision the app
        /// will use if the user taps it.
        case delivered(level: InterruptionLevel, wasDemoted: Bool, route: RouteDecision)
        /// Dropped: exact or logical re-delivery.
        case droppedDuplicate
        /// Dropped: a newer update for the same collapse group was already
        /// processed; showing this one would replace fresh data with stale.
        case droppedStale(latestSeen: UInt64)
    }

    public let messageID: String
    public let disposition: Disposition

    public init(messageID: String, disposition: Disposition) {
        self.messageID = messageID
        self.disposition = disposition
    }
}

/// Aggregate counters for dashboards and the demo UI.
public struct PipelineStats: Sendable, Equatable {
    public var ingested: Int = 0
    public var delivered: Int = 0
    public var demoted: Int = 0
    public var duplicatesDropped: Int = 0
    public var staleDropped: Int = 0

    public init() {}
}

/// End-to-end client-side push ingest pipeline:
///
/// ```
/// RawPushMessage ─▶ deduplicate ─▶ classify (budget) ─▶ route-parse ─▶ outcome
///                        │                                    │
///                     dropped                          (on user tap)
///                                                      RouteDispatcher
/// ```
///
/// ## Stage ordering is load-bearing
/// 1. **Dedup runs first.** A duplicate must never consume attention budget:
///    if classification ran first, a re-delivered time-sensitive push would
///    burn budget and could demote the *next* genuine one.
/// 2. **Staleness beats budget.** An out-of-order arrival is dropped before
///    any presentation decision — there is no level at which stale data is
///    the right thing to show.
/// 3. **Routing never fails.** Route parsing happens at ingest so a bad deep
///    link is discovered (and logged) on arrival, not at tap time — but
///    dispatch is deferred to `open(_:)` because navigation is a *tap*
///    consequence, not an *arrival* consequence.
///
/// ## Concurrency
/// The pipeline is an actor: `ingest(_:)` calls are processed one at a time
/// in call order, so dedup/classification decisions are serialized and the
/// audit trail reflects the true processing order.
public actor PushIngestPipeline {
    private let deduplicator: NotificationDeduplicator
    private let classifier: InterruptionClassifier
    private let router: DeepLinkRouter
    private let dispatcher: RouteDispatcher

    private var stats = PipelineStats()
    private var recent: [IngestOutcome] = []
    private let recentLimit = 200

    public init(
        deduplicator: NotificationDeduplicator,
        classifier: InterruptionClassifier,
        router: DeepLinkRouter,
        dispatcher: RouteDispatcher
    ) {
        self.deduplicator = deduplicator
        self.classifier = classifier
        self.router = router
        self.dispatcher = dispatcher
    }

    /// Process one arriving push message.
    @discardableResult
    public func ingest(_ message: RawPushMessage) async -> IngestOutcome {
        stats.ingested += 1

        // Stage 1 — deduplication (before anything can consume budget).
        switch await deduplicator.evaluate(message) {
        case .duplicateDelivery:
            stats.duplicatesDropped += 1
            return record(IngestOutcome(messageID: message.messageID, disposition: .droppedDuplicate))
        case .staleOutOfOrder(let latest):
            stats.staleDropped += 1
            return record(IngestOutcome(
                messageID: message.messageID,
                disposition: .droppedStale(latestSeen: latest)
            ))
        case .fresh:
            break
        }

        // Stage 2 — classification under the attention budget.
        let classification = await classifier.classify(message)
        let wasDemoted: Bool
        if case .demoted = classification {
            wasDemoted = true
            stats.demoted += 1
        } else {
            wasDemoted = false
        }

        // Stage 3 — route parsing (total: always yields a usable decision).
        let route = router.route(message.deepLink)

        stats.delivered += 1
        return record(IngestOutcome(
            messageID: message.messageID,
            disposition: .delivered(
                level: classification.effectiveLevel,
                wasDemoted: wasDemoted,
                route: route
            )
        ))
    }

    /// The user tapped a delivered notification: dispatch its route. Buffered
    /// automatically if the UI is not ready yet (cold-start tap).
    @discardableResult
    public func open(_ decision: RouteDecision) async -> RouteDispatchOutcome {
        await dispatcher.dispatch(decision.effectiveRoute)
    }

    /// Signal that the UI is ready to receive routes; replays buffered taps.
    @discardableResult
    public func markUIReady() async -> [ResolvedRoute] {
        await dispatcher.markReady()
    }

    public func currentStats() -> PipelineStats { stats }

    /// Most recent outcomes, oldest first (bounded to the last 200).
    public func recentOutcomes() -> [IngestOutcome] { recent }

    // MARK: Internals

    private func record(_ outcome: IngestOutcome) -> IngestOutcome {
        recent.append(outcome)
        if recent.count > recentLimit {
            recent.removeFirst(recent.count - recentLimit)
        }
        return outcome
    }
}
