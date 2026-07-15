import Foundation

/// Interruption level a notification should be presented at, mirroring the
/// semantics of `UNNotificationInterruptionLevel` without importing
/// `UserNotifications` (the adapter at the app edge maps 1:1).
public enum InterruptionLevel: String, Sendable, Equatable, CaseIterable {
    case passive
    case active
    case timeSensitive = "time-sensitive"
    case critical

    /// Parse a server-supplied hint. Unknown or missing hints degrade to
    /// `.active` — the standard level — rather than failing or, worse,
    /// escalating. A typo on the server must never grant a notification more
    /// attention than it was entitled to.
    public static func fromHint(_ hint: String?) -> InterruptionLevel {
        switch hint?.lowercased() {
        case "passive": return .passive
        case "active": return .active
        case "time-sensitive", "timesensitive", "time_sensitive": return .timeSensitive
        case "critical": return .critical
        default: return .active
        }
    }
}

/// Budget for attention-expensive notifications.
public struct AttentionBudgetPolicy: Sendable {
    /// How many `.timeSensitive` deliveries are allowed per rolling window
    /// (clamped to ≥ 0; 0 means every time-sensitive push is demoted).
    public let timeSensitivePerWindow: Int
    /// Rolling window length in seconds (clamped to ≥ 1).
    public let window: TimeInterval

    public init(timeSensitivePerWindow: Int = 3, window: TimeInterval = 300) {
        self.timeSensitivePerWindow = max(0, timeSensitivePerWindow)
        self.window = max(1, window)
    }
}

/// The classifier's decision for one message.
public enum ClassificationOutcome: Sendable, Equatable {
    case deliver(InterruptionLevel)
    /// Delivered, but at a lower level than the server asked for because the
    /// attention budget for the requested level was exhausted.
    case demoted(from: InterruptionLevel, to: InterruptionLevel)

    /// The level the notification will actually be presented at.
    public var effectiveLevel: InterruptionLevel {
        switch self {
        case .deliver(let level): return level
        case .demoted(_, let to): return to
        }
    }
}

/// Maps server interruption hints to presentation levels and enforces a
/// client-side attention budget on `.timeSensitive` notifications.
///
/// ## Design decisions
/// - **Demote, never drop.** Budget overflow demotes time-sensitive pushes to
///   `.active` instead of suppressing them. Notifications are user data; a
///   governance layer that silently discards them turns a UX policy into a
///   data-loss bug. Demotion preserves content while protecting attention.
/// - **`.critical` is exempt.** Critical alerts are entitlement-gated by the
///   OS precisely because they matter (medical, security, safety). A client
///   budget must never stand between the user and one — so critical bypasses
///   the budget entirely, by design, and there is a test pinning that.
/// - **Budget applies at *arrival* classification.** Duplicates never reach
///   the classifier (the pipeline deduplicates first), so re-deliveries
///   cannot burn budget — the ordering of pipeline stages is load-bearing
///   and documented in `PushIngestPipeline`.
public actor InterruptionClassifier {
    private let policy: AttentionBudgetPolicy
    private let clock: any PipelineClock
    private var recentTimeSensitive: [Date] = []

    public init(
        policy: AttentionBudgetPolicy = AttentionBudgetPolicy(),
        clock: any PipelineClock = SystemPipelineClock()
    ) {
        self.policy = policy
        self.clock = clock
    }

    public func classify(_ message: RawPushMessage) -> ClassificationOutcome {
        let requested = InterruptionLevel.fromHint(message.interruptionHint)
        guard requested == .timeSensitive else {
            // passive/active are cheap; critical is exempt by design.
            return .deliver(requested)
        }
        let now = clock.now()
        recentTimeSensitive.removeAll { now.timeIntervalSince($0) > policy.window }
        if recentTimeSensitive.count < policy.timeSensitivePerWindow {
            recentTimeSensitive.append(now)
            return .deliver(.timeSensitive)
        }
        return .demoted(from: .timeSensitive, to: .active)
    }

    /// Number of time-sensitive deliveries currently counted in the window.
    public func consumedBudget() -> Int {
        let now = clock.now()
        return recentTimeSensitive.filter { now.timeIntervalSince($0) <= policy.window }.count
    }
}
