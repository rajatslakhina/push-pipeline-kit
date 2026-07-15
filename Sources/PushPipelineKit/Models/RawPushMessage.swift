import Foundation

/// A transport-agnostic representation of one delivered push message.
///
/// `PushPipelineKit` deliberately does not import `UserNotifications` or
/// `UIKit`: every stage of the pipeline operates on this neutral value type so
/// the whole system is unit-testable on any platform, including Linux CI. The
/// app layer owns a thin adapter that maps `UNNotificationContent` / launch
/// `userInfo` dictionaries into `RawPushMessage` at the process boundary.
public struct RawPushMessage: Sendable, Equatable {
    /// Unique identifier of this *delivery attempt* (mirrors `apns-unique-id`).
    /// Two deliveries of the same logical notification carry different IDs.
    public let messageID: String

    /// Logical identity shared by re-sends and updates of the same
    /// notification (mirrors the semantics of the `apns-collapse-id` header).
    /// `nil` means the message has no logical grouping and is deduplicated by
    /// `messageID` alone.
    public let collapseID: String?

    /// Server-assigned, monotonically increasing sequence number *within a
    /// collapse ID*. Used to reject stale out-of-order arrivals — wall-clock
    /// timestamps are deliberately not used for ordering because client/server
    /// clock skew makes them unreliable. `nil` disables ordering checks for
    /// this message.
    public let sequence: UInt64?

    /// Raw interruption-level hint from the server payload
    /// (e.g. `"time-sensitive"`). Unknown or missing values degrade to a safe
    /// default during classification; they never fail the pipeline.
    public let interruptionHint: String?

    public let title: String
    public let body: String

    /// Optional deep link (e.g. `app://orders/1234?tab=tracking`). Malformed
    /// values never fail the pipeline; they resolve to the fallback route.
    public let deepLink: String?

    public init(
        messageID: String,
        collapseID: String? = nil,
        sequence: UInt64? = nil,
        interruptionHint: String? = nil,
        title: String,
        body: String,
        deepLink: String? = nil
    ) {
        self.messageID = messageID
        self.collapseID = collapseID
        self.sequence = sequence
        self.interruptionHint = interruptionHint
        self.title = title
        self.body = body
        self.deepLink = deepLink
    }
}

/// Abstraction over "now" so every time-dependent component in the pipeline is
/// deterministic under test. Production code uses `SystemPipelineClock`.
public protocol PipelineClock: Sendable {
    func now() -> Date
}

/// The production clock: wall-clock time.
public struct SystemPipelineClock: PipelineClock {
    public init() {}
    public func now() -> Date { Date() }
}
