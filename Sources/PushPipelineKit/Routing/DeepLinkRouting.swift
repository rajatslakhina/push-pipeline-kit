import Foundation

// MARK: - Parsing

/// Structured, validated form of a deep link.
public struct DeepLinkComponents: Sendable, Equatable {
    public let scheme: String
    public let host: String
    public let pathSegments: [String]
    public let queryParameters: [String: String]

    public init(
        scheme: String,
        host: String,
        pathSegments: [String],
        queryParameters: [String: String]
    ) {
        self.scheme = scheme
        self.host = host
        self.pathSegments = pathSegments
        self.queryParameters = queryParameters
    }
}

/// Strict deep-link parser. Anything that does not parse into an allowed
/// scheme with a non-empty host is rejected (`nil`) — the router then falls
/// back rather than crashing or guessing. Push payloads are remote input and
/// are treated with the same suspicion as any other untrusted data.
public struct DeepLinkParser: Sendable {
    public let allowedSchemes: Set<String>

    public init(allowedSchemes: Set<String> = ["app"]) {
        self.allowedSchemes = Set(allowedSchemes.map { $0.lowercased() })
    }

    public func parse(_ raw: String) -> DeepLinkComponents? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              allowedSchemes.contains(scheme),
              let host = components.host, !host.isEmpty
        else { return nil }

        let segments = components.path.split(separator: "/").map(String.init)
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] {
            // First occurrence wins; later duplicates are ignored. Documented
            // rather than accidental: repeated query keys in a push payload
            // are a malformed-input smell, not a feature.
            if parameters[item.name] == nil {
                parameters[item.name] = item.value ?? ""
            }
        }
        return DeepLinkComponents(
            scheme: scheme,
            host: host,
            pathSegments: segments,
            queryParameters: parameters
        )
    }
}

// MARK: - Resolution

/// A typed destination inside the app.
public struct ResolvedRoute: Sendable, Equatable, Hashable {
    public let identifier: String
    public let parameters: [String: String]

    public init(identifier: String, parameters: [String: String] = [:]) {
        self.identifier = identifier
        self.parameters = parameters
    }
}

/// One entry in the resolver chain: turns validated components into a typed
/// route, or declines by returning `nil` so the next resolver can try.
public protocol RouteResolving: Sendable {
    func resolve(_ components: DeepLinkComponents) -> ResolvedRoute?
}

/// Closure-based resolver for lightweight registration.
public struct ClosureRouteResolver: RouteResolving {
    private let body: @Sendable (DeepLinkComponents) -> ResolvedRoute?

    public init(_ body: @escaping @Sendable (DeepLinkComponents) -> ResolvedRoute?) {
        self.body = body
    }

    public func resolve(_ components: DeepLinkComponents) -> ResolvedRoute? {
        body(components)
    }
}

/// Why the router fell back instead of resolving a typed route.
public enum RouteFallbackReason: Sendable, Equatable {
    case missingLink
    case malformedLink
    case unresolvedLink
}

public enum RouteDecision: Sendable, Equatable {
    case resolved(ResolvedRoute)
    case fallback(ResolvedRoute, reason: RouteFallbackReason)

    /// The route that will actually be opened, whichever way it was decided.
    public var effectiveRoute: ResolvedRoute {
        switch self {
        case .resolved(let route): return route
        case .fallback(let route, _): return route
        }
    }
}

/// First-match-wins resolver chain with a guaranteed total outcome: every
/// input — including `nil`, garbage, and unrecognized-but-valid links —
/// resolves to *some* route. A push tap must always land the user somewhere
/// sensible; "crash on malformed payload" and "silently do nothing" are both
/// failure modes this type exists to make unrepresentable.
public struct DeepLinkRouter: Sendable {
    private let parser: DeepLinkParser
    private let resolvers: [any RouteResolving]
    private let fallbackRoute: ResolvedRoute

    public init(
        parser: DeepLinkParser = DeepLinkParser(),
        resolvers: [any RouteResolving],
        fallbackRoute: ResolvedRoute
    ) {
        self.parser = parser
        self.resolvers = resolvers
        self.fallbackRoute = fallbackRoute
    }

    public func route(_ rawLink: String?) -> RouteDecision {
        guard let rawLink, !rawLink.isEmpty else {
            return .fallback(fallbackRoute, reason: .missingLink)
        }
        guard let components = parser.parse(rawLink) else {
            return .fallback(fallbackRoute, reason: .malformedLink)
        }
        for resolver in resolvers {
            if let route = resolver.resolve(components) {
                return .resolved(route)
            }
        }
        return .fallback(fallbackRoute, reason: .unresolvedLink)
    }
}

// MARK: - Dispatch (cold-start buffering)

/// Outcome of asking the dispatcher to open a route.
public enum RouteDispatchOutcome: Sendable, Equatable {
    case delivered
    /// UI not ready yet; buffered for replay (depth after buffering).
    case buffered(depth: Int)
    /// Buffer was full; oldest pending route was evicted to make room.
    case bufferedEvictingOldest(evicted: ResolvedRoute)
}

/// Buffers route dispatches that arrive before the UI is ready, then replays
/// them in arrival order.
///
/// The race is real: a notification tap can launch the app, and the route
/// arrives while the scene graph is still being built. Dropping the tap is a
/// broken user promise ("I tapped the order update and got the home screen").
/// The dispatcher holds routes until `markReady()` and replays FIFO.
///
/// The buffer is bounded with drop-oldest overflow: if many routes pile up
/// pre-ready, the newest intents win — the user's most recent tap is the one
/// they still remember making.
public actor RouteDispatcher {
    private let bufferLimit: Int
    private let deliver: @Sendable (ResolvedRoute) -> Void
    private var isReady = false
    private var pending: [ResolvedRoute] = []

    public init(
        bufferLimit: Int = 8,
        deliver: @escaping @Sendable (ResolvedRoute) -> Void
    ) {
        self.bufferLimit = max(1, bufferLimit)
        self.deliver = deliver
    }

    @discardableResult
    public func dispatch(_ route: ResolvedRoute) -> RouteDispatchOutcome {
        guard isReady else {
            if pending.count >= bufferLimit {
                // Safe: pending.count >= bufferLimit >= 1, so removeFirst
                // cannot act on an empty array.
                let evicted = pending.removeFirst()
                pending.append(route)
                return .bufferedEvictingOldest(evicted: evicted)
            }
            pending.append(route)
            return .buffered(depth: pending.count)
        }
        deliver(route)
        return .delivered
    }

    /// Mark the UI ready and replay everything buffered, in arrival order.
    /// Returns the replayed routes (useful for tests and logging).
    @discardableResult
    public func markReady() -> [ResolvedRoute] {
        isReady = true
        let replay = pending
        pending.removeAll()
        for route in replay {
            deliver(route)
        }
        return replay
    }

    /// Re-enter buffering mode (e.g. scene torn down on memory pressure).
    public func markNotReady() {
        isReady = false
    }

    public func pendingCount() -> Int { pending.count }
}
