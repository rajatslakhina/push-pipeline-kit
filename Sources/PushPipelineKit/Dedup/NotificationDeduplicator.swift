import Foundation

/// The deduplicator's verdict for one incoming message.
public enum DeduplicationVerdict: Sendable, Equatable {
    /// Never seen before — process it.
    case fresh
    /// A re-delivery: either the exact same delivery attempt (`messageID`
    /// already seen) or the same logical update (equal sequence within the
    /// same collapse group under a different `messageID`).
    case duplicateDelivery
    /// An out-of-order arrival: a *newer* update for this collapse group has
    /// already been processed. Presenting this one would show the user stale
    /// data over fresh data.
    case staleOutOfOrder(latestSeen: UInt64)
}

/// Counters for observability dashboards and the demo UI.
public struct DeduplicationStats: Sendable, Equatable {
    public var trackedMessages: Int = 0
    public var trackedCollapseGroups: Int = 0
    public var freshAccepted: Int = 0
    public var duplicatesDropped: Int = 0
    public var staleDropped: Int = 0
}

/// Bounded-memory notification deduplicator.
///
/// Push delivery is at-least-once in practice: silent-push retries, dual
/// delivery channels (APNs + live socket), and provider-side re-sends all
/// produce the same logical notification more than once. At 50M devices even
/// a 0.1% duplicate rate is 50k duplicate banners a day — deduplication is a
/// client responsibility, not an edge case.
///
/// ## Design decisions
/// - **Two identity layers.** Exact re-deliveries are caught by `messageID`;
///   logical duplicates and stale out-of-order updates are caught by
///   (`collapseID`, `sequence`). Sequence numbers are server-assigned:
///   wall-clock timestamps are deliberately rejected for ordering because
///   client/server clock skew makes them lie.
/// - **Bounded memory, FIFO eviction.** Both identity tables are capped and
///   evict oldest-inserted first. True LRU would add bookkeeping for no
///   practical win here: the time window, not recency of *lookup*, is what
///   bounds correctness. Evicting a collapse group forfeits stale-detection
///   for that group only — a documented, bounded degradation rather than
///   unbounded growth.
/// - **Stale messages are still remembered.** A stale arrival records its
///   `messageID` so *its own* re-delivery is later classified as a duplicate,
///   keeping counters truthful.
public actor NotificationDeduplicator {
    private let capacity: Int
    private let window: TimeInterval
    private let clock: any PipelineClock

    private var seenAt: [String: Date] = [:]
    private var seenOrder: [String] = []
    private var latestSequence: [String: UInt64] = [:]
    private var collapseOrder: [String] = []
    private var stats = DeduplicationStats()

    /// - Parameters:
    ///   - capacity: max tracked identities per table (clamped to ≥ 1).
    ///   - window: how long a `messageID` is remembered (clamped to ≥ 1s).
    public init(
        capacity: Int = 512,
        window: TimeInterval = 600,
        clock: any PipelineClock = SystemPipelineClock()
    ) {
        self.capacity = max(1, capacity)
        self.window = max(1, window)
        self.clock = clock
    }

    public func evaluate(_ message: RawPushMessage) -> DeduplicationVerdict {
        let now = clock.now()
        purgeExpired(now: now)

        // Layer 1 — exact re-delivery of the same attempt.
        if seenAt[message.messageID] != nil {
            stats.duplicatesDropped += 1
            return .duplicateDelivery
        }

        // Layer 2 — logical ordering within a collapse group.
        if let collapse = message.collapseID, let sequence = message.sequence {
            if let latest = latestSequence[collapse] {
                if sequence < latest {
                    remember(messageID: message.messageID, at: now)
                    stats.staleDropped += 1
                    return .staleOutOfOrder(latestSeen: latest)
                }
                if sequence == latest {
                    remember(messageID: message.messageID, at: now)
                    stats.duplicatesDropped += 1
                    return .duplicateDelivery
                }
            }
            rememberSequence(collapse: collapse, sequence: sequence)
        }

        remember(messageID: message.messageID, at: now)
        stats.freshAccepted += 1
        return .fresh
    }

    public func currentStats() -> DeduplicationStats {
        var snapshot = stats
        snapshot.trackedMessages = seenOrder.count
        snapshot.trackedCollapseGroups = collapseOrder.count
        return snapshot
    }

    // MARK: Internals

    private func remember(messageID: String, at date: Date) {
        if seenAt[messageID] == nil {
            seenOrder.append(messageID)
        }
        seenAt[messageID] = date
        while seenOrder.count > capacity, !seenOrder.isEmpty {
            let evicted = seenOrder.removeFirst()
            seenAt[evicted] = nil
        }
    }

    private func rememberSequence(collapse: String, sequence: UInt64) {
        if latestSequence[collapse] == nil {
            collapseOrder.append(collapse)
        }
        latestSequence[collapse] = sequence
        while collapseOrder.count > capacity, !collapseOrder.isEmpty {
            let evicted = collapseOrder.removeFirst()
            latestSequence[evicted] = nil
        }
    }

    private func purgeExpired(now: Date) {
        // seenOrder is insertion-ordered and the pipeline clock is
        // non-decreasing, so expired entries cluster at the front.
        while let oldest = seenOrder.first,
              let insertedAt = seenAt[oldest],
              now.timeIntervalSince(insertedAt) > window {
            seenOrder.removeFirst()
            seenAt[oldest] = nil
        }
        // Defensive: drop any orphaned head entry whose timestamp is missing
        // (cannot happen if the two structures stay in sync, but a bounds bug
        // here must degrade to eviction, never to a stuck loop or crash).
        while let oldest = seenOrder.first, seenAt[oldest] == nil {
            seenOrder.removeFirst()
        }
    }
}
