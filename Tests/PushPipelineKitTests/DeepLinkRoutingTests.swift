import XCTest
@testable import PushPipelineKit

final class DeepLinkRoutingTests: XCTestCase {

    private let fallback = ResolvedRoute(identifier: "home")

    private func makeRouter(resolvers: [any RouteResolving]? = nil) -> DeepLinkRouter {
        let orderResolver = ClosureRouteResolver { components in
            guard components.host == "orders",
                  let orderID = components.pathSegments.first else { return nil }
            var parameters = components.queryParameters
            parameters["orderID"] = orderID
            return ResolvedRoute(identifier: "orderDetail", parameters: parameters)
        }
        let settingsResolver = ClosureRouteResolver { components in
            guard components.host == "settings" else { return nil }
            return ResolvedRoute(identifier: "settings")
        }
        return DeepLinkRouter(
            parser: DeepLinkParser(allowedSchemes: ["app"]),
            resolvers: resolvers ?? [orderResolver, settingsResolver],
            fallbackRoute: fallback
        )
    }

    // MARK: Parser

    func testParserAcceptsWellFormedLink() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        let components = parser.parse("app://orders/1234?tab=tracking")
        XCTAssertEqual(components?.scheme, "app")
        XCTAssertEqual(components?.host, "orders")
        XCTAssertEqual(components?.pathSegments, ["1234"])
        XCTAssertEqual(components?.queryParameters, ["tab": "tracking"])
    }

    func testParserRejectsDisallowedScheme() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        XCTAssertNil(parser.parse("https://evil.example.com/phish"))
    }

    func testParserRejectsMissingHostAndEmptyInput() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        XCTAssertNil(parser.parse("app://"))
        XCTAssertNil(parser.parse(""))
        XCTAssertNil(parser.parse("   "))
        XCTAssertNil(parser.parse("not a url at all %% ::"))
    }

    func testParserDecodesPercentEncodedQueryValues() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        let components = parser.parse("app://search/results?q=iphone%2015%20pro")
        XCTAssertEqual(components?.queryParameters["q"], "iphone 15 pro")
    }

    func testParserFirstQueryOccurrenceWins() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        let components = parser.parse("app://orders/1?tab=one&tab=two")
        XCTAssertEqual(components?.queryParameters["tab"], "one")
    }

    func testParserHandlesEmptyQueryValueWithoutCrashing() {
        let parser = DeepLinkParser(allowedSchemes: ["app"])
        let components = parser.parse("app://orders/1?flag")
        XCTAssertEqual(components?.queryParameters["flag"], "")
    }

    // MARK: Router

    func testRouterResolvesTypedRouteWithParameters() {
        let decision = makeRouter().route("app://orders/1234?tab=tracking")
        XCTAssertEqual(
            decision,
            .resolved(ResolvedRoute(
                identifier: "orderDetail",
                parameters: ["tab": "tracking", "orderID": "1234"]
            ))
        )
    }

    func testRouterChainRespectsOrderFirstMatchWins() {
        let greedy = ClosureRouteResolver { _ in ResolvedRoute(identifier: "greedy") }
        let never = ClosureRouteResolver { _ in
            XCTFail("Second resolver must not be consulted after a match")
            return nil
        }
        let router = DeepLinkRouter(resolvers: [greedy, never], fallbackRoute: fallback)
        let decision = router.route("app://anything/at/all")
        XCTAssertEqual(decision, .resolved(ResolvedRoute(identifier: "greedy")))
    }

    func testRouterFallsBackOnMissingMalformedAndUnresolved() {
        let router = makeRouter()
        XCTAssertEqual(router.route(nil), .fallback(fallback, reason: .missingLink))
        XCTAssertEqual(router.route(""), .fallback(fallback, reason: .missingLink))
        XCTAssertEqual(router.route("::::"), .fallback(fallback, reason: .malformedLink))
        XCTAssertEqual(
            router.route("app://unknown-surface/x"),
            .fallback(fallback, reason: .unresolvedLink)
        )
    }

    // MARK: Dispatcher

    func testDispatcherDeliversImmediatelyWhenReady() async {
        let recorder = RouteRecorder()
        let dispatcher = RouteDispatcher(bufferLimit: 4) { recorder.append($0) }
        await dispatcher.markReady()
        let outcome = await dispatcher.dispatch(ResolvedRoute(identifier: "r1"))
        XCTAssertEqual(outcome, .delivered)
        XCTAssertEqual(recorder.routes, [ResolvedRoute(identifier: "r1")])
    }

    func testDispatcherBuffersBeforeReadyAndReplaysInOrder() async {
        let recorder = RouteRecorder()
        let dispatcher = RouteDispatcher(bufferLimit: 4) { recorder.append($0) }
        _ = await dispatcher.dispatch(ResolvedRoute(identifier: "r1"))
        _ = await dispatcher.dispatch(ResolvedRoute(identifier: "r2"))
        XCTAssertTrue(recorder.routes.isEmpty, "Nothing delivered before ready")

        let replayed = await dispatcher.markReady()
        XCTAssertEqual(replayed.map(\.identifier), ["r1", "r2"])
        XCTAssertEqual(recorder.routes.map(\.identifier), ["r1", "r2"], "FIFO replay")
    }

    func testDispatcherOverflowEvictsOldest() async {
        let recorder = RouteRecorder()
        let dispatcher = RouteDispatcher(bufferLimit: 2) { recorder.append($0) }
        _ = await dispatcher.dispatch(ResolvedRoute(identifier: "r1"))
        _ = await dispatcher.dispatch(ResolvedRoute(identifier: "r2"))
        let overflow = await dispatcher.dispatch(ResolvedRoute(identifier: "r3"))
        XCTAssertEqual(overflow, .bufferedEvictingOldest(evicted: ResolvedRoute(identifier: "r1")))

        let replayed = await dispatcher.markReady()
        XCTAssertEqual(replayed.map(\.identifier), ["r2", "r3"], "Newest intents win")
    }

    func testDispatcherBufferLimitClampsToAtLeastOne() async {
        let recorder = RouteRecorder()
        let dispatcher = RouteDispatcher(bufferLimit: -3) { recorder.append($0) }
        let first = await dispatcher.dispatch(ResolvedRoute(identifier: "r1"))
        XCTAssertEqual(first, .buffered(depth: 1))
        let second = await dispatcher.dispatch(ResolvedRoute(identifier: "r2"))
        XCTAssertEqual(second, .bufferedEvictingOldest(evicted: ResolvedRoute(identifier: "r1")))
    }

    func testDispatcherMarkNotReadyResumesBuffering() async {
        let recorder = RouteRecorder()
        let dispatcher = RouteDispatcher(bufferLimit: 4) { recorder.append($0) }
        await dispatcher.markReady()
        _ = await dispatcher.dispatch(ResolvedRoute(identifier: "r1"))
        await dispatcher.markNotReady()
        let outcome = await dispatcher.dispatch(ResolvedRoute(identifier: "r2"))
        XCTAssertEqual(outcome, .buffered(depth: 1))
        let pendingCount = await dispatcher.pendingCount()
        XCTAssertEqual(pendingCount, 1)
    }
}
