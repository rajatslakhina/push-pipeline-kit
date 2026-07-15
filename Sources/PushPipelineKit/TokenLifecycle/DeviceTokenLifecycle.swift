import Foundation

// MARK: - Public protocol seams

/// The app-server call that associates an APNs device token with the current
/// user/device record. Injected so the lifecycle state machine is fully
/// testable, and so the transport (URLSession, gRPC, GraphQL…) stays an
/// app-layer decision.
public protocol TokenRegistrationTransport: Sendable {
    func register(token: String) async throws
}

/// Abstraction over "wait before retrying" so tests run instantly and can
/// assert the exact backoff schedule that production would use.
public protocol RetryScheduling: Sendable {
    func wait(_ interval: TimeInterval) async throws
}

/// Production scheduler backed by `Task.sleep`.
public struct TaskSleepScheduler: RetryScheduling {
    public init() {}
    public func wait(_ interval: TimeInterval) async throws {
        // Clamp both ends: negative intervals become 0, and absurdly large
        // intervals are capped at one hour so the Double→UInt64 conversion
        // below can never trap on overflow.
        let clamped = min(max(0, interval), 3_600)
        try await Task.sleep(nanoseconds: UInt64(clamped * 1_000_000_000))
    }
}

// MARK: - Retry policy

/// Exponential backoff with optional full jitter for server registration
/// retries. Full jitter (interval × U[0,1)) is the storm-safe default: when a
/// fleet of devices all fail registration at once (server deploy, outage
/// recovery), deterministic backoff re-synchronizes their retries into
/// coordinated waves; jitter spreads them out.
public struct RegistrationRetryPolicy: Sendable {
    /// Total attempts including the first (clamped to at least 1).
    public let maxAttempts: Int
    public let baseInterval: TimeInterval
    public let maxInterval: TimeInterval
    /// When `true`, each computed interval is multiplied by `randomUnit()`.
    public let useFullJitter: Bool
    /// Uniform random value in [0, 1). Injected so tests are deterministic.
    public let randomUnit: @Sendable () -> Double

    public init(
        maxAttempts: Int = 5,
        baseInterval: TimeInterval = 1.0,
        maxInterval: TimeInterval = 60.0,
        useFullJitter: Bool = true,
        randomUnit: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) }
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseInterval = max(0, baseInterval)
        self.maxInterval = max(0, maxInterval)
        self.useFullJitter = useFullJitter
        self.randomUnit = randomUnit
    }

    /// Backoff interval to wait *after* the given failed attempt (1-based).
    /// The exponent is capped so the computation stays finite for any input.
    public func interval(afterAttempt attempt: Int) -> TimeInterval {
        let normalized = max(1, attempt)
        let exponent = min(normalized - 1, 16) // 2^16 cap prevents overflow
        let raw = baseInterval * pow(2, Double(exponent))
        let capped = min(raw, maxInterval)
        return useFullJitter ? capped * randomUnit() : capped
    }
}

// MARK: - States, directives, audit

/// Why a token is parked (registration abandoned until explicitly retried).
public enum TokenParkReason: Sendable, Equatable {
    case retryBudgetExhausted(lastErrorDescription: String)
}

/// The token lifecycle state machine's externally observable states.
public enum TokenState: Sendable, Equatable {
    /// No token has ever been received from the OS.
    case unregistered
    /// A token is being registered with the app server (attempt is 1-based).
    case registering(token: String, generation: UInt64, attempt: Int)
    /// The app server has acknowledged this token.
    case registered(token: String, generation: UInt64)
    /// Registration failed `maxAttempts` times; waiting for `retryNow()` or a
    /// fresh token. Deliberately not retried forever: an unattended retry loop
    /// with no ceiling is a battery and server-load hazard.
    case parked(token: String, generation: UInt64, reason: TokenParkReason)
    /// The server reported the token dead (e.g. APNs 410 Unregistered relayed
    /// by the app server). The caller must request a fresh token from the OS.
    case invalidated(generation: UInt64)
}

/// What the caller should do next after feeding an event into the machine.
public enum TokenDirective: Sendable, Equatable {
    case none
    /// Re-invoke the OS token request
    /// (`UIApplication.registerForRemoteNotifications()` in a real app).
    case requestFreshToken
}

/// Append-only audit trail of every decision the state machine makes, so
/// "why is this device not receiving pushes" is answerable from a log dump.
public enum TokenAuditEvent: Sendable, Equatable {
    case tokenAccepted(generation: UInt64)
    case emptyTokenIgnored
    case duplicateTokenIgnored
    case registrationSucceeded(generation: UInt64)
    case registrationAttemptFailed(generation: UInt64, attempt: Int)
    case parked(generation: UInt64)
    case staleCompletionDiscarded(generation: UInt64, current: UInt64)
    case invalidatedByServer(previousGeneration: UInt64)
    case manualRetryRequested(generation: UInt64)
}

// MARK: - The state machine

/// Actor-isolated APNs device-token lifecycle manager.
///
/// ## Concurrency and ordering guarantees
/// - **Generation monotonicity.** Every accepted token (and every server-side
///   invalidation) increments a generation counter. A registration completion
///   is applied **only if its generation still equals the current one**; late
///   completions from superseded registrations are discarded, never applied.
///   This is how the classic race — token rotates while the previous token's
///   registration is still in flight — is made harmless.
/// - **Discard, don't cancel.** Superseded registrations are not cancelled;
///   they are allowed to finish and their results dropped. Cancellation is
///   cooperative and cannot un-send a request the transport already committed
///   server-side, so correctness must not depend on it. The generation check
///   is the single source of truth.
/// - **Bounded retries.** Registration failures back off exponentially (with
///   full jitter by default) up to `maxAttempts`, then park. Parked state is
///   escaped only by `retryNow()` or a fresh token.
public actor DeviceTokenLifecycle {
    private let transport: any TokenRegistrationTransport
    private let policy: RegistrationRetryPolicy
    private let scheduler: any RetryScheduling

    public private(set) var state: TokenState = .unregistered
    private var currentGeneration: UInt64 = 0
    private var inFlight: [UInt64: Task<Void, Never>] = [:]
    private var audit: [TokenAuditEvent] = []
    private let auditLimit = 100

    public init(
        transport: any TokenRegistrationTransport,
        policy: RegistrationRetryPolicy = RegistrationRetryPolicy(),
        scheduler: any RetryScheduling = TaskSleepScheduler()
    ) {
        self.transport = transport
        self.policy = policy
        self.scheduler = scheduler
    }

    // MARK: Events

    /// Feed a token received from the OS (initial grant or rotation).
    @discardableResult
    public func tokenReceived(_ token: String) -> TokenDirective {
        guard !token.isEmpty else {
            record(.emptyTokenIgnored)
            return .none
        }
        // APNs can hand the app the same token repeatedly (every launch).
        // Re-registering an already-acknowledged token is a pointless server
        // call, so it is explicitly ignored.
        if case .registered(let existing, _) = state, existing == token {
            record(.duplicateTokenIgnored)
            return .none
        }
        currentGeneration += 1
        let generation = currentGeneration
        record(.tokenAccepted(generation: generation))
        startRegistration(token: token, generation: generation)
        return .none
    }

    /// Feed a server-side signal that the current token is dead
    /// (e.g. the app server relayed an APNs 410 Unregistered for it).
    @discardableResult
    public func serverReportedInvalid() -> TokenDirective {
        let previous = currentGeneration
        // Bumping the generation obsoletes any in-flight registration.
        currentGeneration += 1
        state = .invalidated(generation: currentGeneration)
        record(.invalidatedByServer(previousGeneration: previous))
        return .requestFreshToken
    }

    /// Escape hatch out of `.parked`: restart registration for the parked
    /// token with a fresh retry budget. No-op in any other state.
    @discardableResult
    public func retryNow() -> TokenDirective {
        guard case .parked(let token, let generation, _) = state,
              generation == currentGeneration else {
            return .none
        }
        record(.manualRetryRequested(generation: generation))
        startRegistration(token: token, generation: generation)
        return .none
    }

    // MARK: Observation

    public func auditEvents() -> [TokenAuditEvent] { audit }

    /// Await completion of all in-flight registration work. Intended for
    /// tests and orderly shutdown; production callers never need it.
    public func settle() async {
        while let entry = inFlight.first {
            await entry.value.value
            // The task removes itself on completion; if it hasn't yet (actor
            // reentrancy), remove it here so the loop always makes progress.
            inFlight[entry.key] = nil
        }
    }

    // MARK: Internals

    private func startRegistration(token: String, generation: UInt64) {
        state = .registering(token: token, generation: generation, attempt: 1)
        // The task retains `self` only until it completes and removes itself
        // from `inFlight`, so no lasting reference cycle is formed.
        inFlight[generation] = Task {
            // The Task closure inherits this actor's isolation, so the
            // cleanup call below is a plain synchronous actor-local call.
            await self.runRegistrationLoop(token: token, generation: generation)
            self.clearInFlight(generation: generation)
        }
    }

    private func clearInFlight(generation: UInt64) {
        inFlight[generation] = nil
    }

    private func runRegistrationLoop(token: String, generation: UInt64) async {
        var attempt = 1
        while true {
            // Every await below is a suspension point where the world can
            // change; re-validate the generation after each one.
            guard generation == currentGeneration else {
                record(.staleCompletionDiscarded(generation: generation, current: currentGeneration))
                return
            }
            state = .registering(token: token, generation: generation, attempt: attempt)
            do {
                try await transport.register(token: token)
                guard generation == currentGeneration else {
                    record(.staleCompletionDiscarded(generation: generation, current: currentGeneration))
                    return
                }
                state = .registered(token: token, generation: generation)
                record(.registrationSucceeded(generation: generation))
                return
            } catch {
                guard generation == currentGeneration else {
                    record(.staleCompletionDiscarded(generation: generation, current: currentGeneration))
                    return
                }
                record(.registrationAttemptFailed(generation: generation, attempt: attempt))
                if attempt >= policy.maxAttempts {
                    state = .parked(
                        token: token,
                        generation: generation,
                        reason: .retryBudgetExhausted(lastErrorDescription: String(describing: error))
                    )
                    record(.parked(generation: generation))
                    return
                }
                let delay = policy.interval(afterAttempt: attempt)
                // A cancelled sleep just means we retry sooner; the generation
                // guard at the top of the loop keeps that safe.
                try? await scheduler.wait(delay)
                attempt += 1
            }
        }
    }

    private func record(_ event: TokenAuditEvent) {
        audit.append(event)
        if audit.count > auditLimit {
            audit.removeFirst(audit.count - auditLimit)
        }
    }
}
