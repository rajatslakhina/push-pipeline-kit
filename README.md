# PushPipelineKit

**The client side of a 50-million-device push notification system, as real, tested Swift.**

Interviewers love to ask how you'd *send* 50M pushes. Almost nobody asks the question that actually pages you at 2 a.m.: what happens on the **device** when delivery is at-least-once, tokens rotate mid-flight, payloads arrive out of order, and a marketing burst lands during a production incident? PushPipelineKit is that answer as code: a transport-agnostic, actor-isolated ingest pipeline covering the four client-side subsystems a staff-level design review would demand — token lifecycle, deduplication, attention budgeting, and typed deep-link routing with cold-start replay.

```
RawPushMessage ─▶ deduplicate ─▶ classify (attention budget) ─▶ route-parse ─▶ present
                       │                                             │ (on tap)
                    dropped                                    RouteDispatcher
                (duplicate / stale)                       (buffers until UI ready)
```

## Why this matters

At fleet scale, "rare" client events are constant events. A 0.1% duplicate-delivery rate across 50M devices is 50,000 duplicate banners a day. A token-rotation race that loses one registration in a million silently kills push for dozens of users every deploy. This library treats each of those as a first-class failure mode with an explicit, tested policy:

- **Token rotation mid-registration** — a generation counter guarantees a late-completing registration of an old token can never overwrite a newer one. Superseded work is *discarded, not cancelled*: cancellation is cooperative and can't un-send a request the server already committed, so correctness never depends on it.
- **At-least-once delivery** — two dedup identity layers: exact re-delivery by `messageID`, logical duplicates and *stale out-of-order updates* by (`collapseID`, server-assigned `sequence`). Timestamps are deliberately rejected for ordering — clock skew makes them lie.
- **Notification floods** — a rolling attention budget demotes (never drops) over-budget time-sensitive pushes; `critical` is exempt by design, with a test pinning that safety rule.
- **Registration retry storms** — exponential backoff with full jitter and a hard retry budget; exhaustion parks the token rather than hammering the server forever.
- **Cold-start taps** — a tap can arrive before the scene graph exists; routes are buffered (bounded, drop-oldest) and replayed FIFO once the UI marks itself ready.
- **Hostile payloads** — deep links are untrusted remote input: strict scheme/host validation, and *every* input — `nil`, garbage, unresolved — totalizes to a usable route. "Crash on malformed payload" is unrepresentable.

## Design decisions (and rejected alternatives)

**Transport-agnostic core.** No `UserNotifications`/`UIKit` import anywhere; the pipeline consumes a neutral `RawPushMessage`. *Rejected:* wrapping `UNUserNotificationCenter` directly — it welds the system to a platform framework, makes Linux CI impossible, and the adapter you'd save is ~20 lines at the app edge.

**Generation counter over task cancellation.** The rotation race is solved with a monotonic generation check after every suspension point. *Rejected:* cancelling superseded registration tasks as the correctness mechanism — cancellation is advisory, can't recall committed server writes, and turns a provable invariant into a timing hope.

**Stage ordering: dedup → budget → route.** Duplicates are dropped *before* classification so a re-delivered time-sensitive push can never burn budget and demote the next genuine one. *Rejected:* classify-first (simpler flow, subtle budget-leak bug).

**Demote, never drop.** Over-budget pushes are delivered at `.active` instead of suppressed. *Rejected:* silent suppression — notifications are user data; a UX-governance layer must not become a data-loss bug.

**FIFO bounded dedup tables.** Both identity tables cap entries and evict oldest-first. *Rejected:* true LRU (recency-of-lookup isn't what bounds correctness here — the time window is) and `NSCache` (no count guarantee, non-deterministic eviction, no Linux).

**Server-assigned sequences over timestamps.** Ordering inside a collapse group uses a `UInt64` sequence; `nil` degrades gracefully to ID-only dedup. *Rejected:* wall-clock ordering — device/server skew reorders honest messages.

## What's tested

54 XCTest cases, all runnable headlessly (they run on Linux in this repo's verification): the full token state machine including the rotation race staged with a gated transport and the exact backoff schedule asserted; dedup eviction under capacity pressure, window expiry, stale/equal/newer sequences, and stats accuracy; budget demotion, window restoration, zero-budget and critical-exemption rules; deep-link parsing of malformed/hostile inputs; dispatcher FIFO replay, overflow eviction, and clamped limits; and end-to-end pipeline dispositions including the duplicates-never-burn-budget invariant.

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/rajatslakhina/push-pipeline-kit.git", branch: "main")
]
```

## Usage

```swift
import PushPipelineKit

let pipeline = PushIngestPipeline(
    deduplicator: NotificationDeduplicator(capacity: 512, window: 600),
    classifier: InterruptionClassifier(policy: AttentionBudgetPolicy(timeSensitivePerWindow: 3, window: 300)),
    router: DeepLinkRouter(
        resolvers: [ClosureRouteResolver { components in
            guard components.host == "orders", let id = components.pathSegments.first else { return nil }
            return ResolvedRoute(identifier: "orderDetail", parameters: ["orderID": id])
        }],
        fallbackRoute: ResolvedRoute(identifier: "home")
    ),
    dispatcher: RouteDispatcher { route in /* navigate */ }
)

let outcome = await pipeline.ingest(message)      // arrival: dedup → classify → parse
if case .delivered(_, _, let route) = outcome.disposition {
    await pipeline.open(route)                    // tap: buffered until markUIReady()
}
```

Token lifecycle runs alongside:

```swift
let lifecycle = DeviceTokenLifecycle(transport: MyRegistrationTransport())
await lifecycle.tokenReceived(apnsTokenHex)           // from the OS delegate callback
let directive = await lifecycle.serverReportedInvalid() // on APNs 410 relayed by your server
if directive == .requestFreshToken { /* re-register with the OS */ }
```

## Demo app

**[push-pipeline-kit-demo-app](https://github.com/rajatslakhina/push-pipeline-kit-demo-app)** — a SwiftUI console that consumes this package as a **remote** SPM dependency (by this repo's GitHub URL, not a local path) and turns every failure mode into a button: duplicate bursts, stale arrivals, time-sensitive floods, token rotation under a failing registration server, malformed deep links, and cold-start tap replay.

## Verification (honest status)

`swift build` (zero warnings) and `swift test` (**54/54 passing**) were run for real on Swift 6.0.3 / Linux for this library. The package contains no app or executable target by design; the runnable SwiftUI demo lives in the companion repo above, which consumes this package as a **remote** SPM dependency — the same way any external consumer would.

## License

MIT
