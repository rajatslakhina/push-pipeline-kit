import Foundation
import XCTest
@testable import PushPipelineKit

// MARK: - Deterministic clock

/// Manually advanced clock. Thread-safe so it can be shared with actors.
final class ManualClock: PipelineClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(start: Date = Date(timeIntervalSince1970: 1_000_000)) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }
}

// MARK: - Scripted registration transport

enum ScriptedError: Error { case scripted }

/// Transport whose per-call behavior is scripted up front. Calls beyond the
/// script succeed.
actor ScriptedTransport: TokenRegistrationTransport {
    enum Step { case succeed, fail }

    private var script: [Step]
    private(set) var registeredTokens: [String] = []
    private(set) var callCount = 0

    init(script: [Step] = []) {
        self.script = script
    }

    func register(token: String) async throws {
        callCount += 1
        registeredTokens.append(token)
        let step = script.isEmpty ? Step.succeed : script.removeFirst()
        if case .fail = step {
            throw ScriptedError.scripted
        }
    }

    func appendScript(_ steps: [Step]) {
        script.append(contentsOf: steps)
    }
}

/// Transport that suspends every `register` call until released, to stage
/// in-flight races deterministically.
actor GatedTransport: TokenRegistrationTransport {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0

    func register(token: String) async throws {
        started += 1
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func releaseAll() {
        while !waiters.isEmpty {
            waiters.removeFirst().resume()
        }
    }
}

// MARK: - Recording scheduler

/// Returns immediately but records every requested wait, so tests can assert
/// the exact backoff schedule.
final class RecordingScheduler: RetryScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [TimeInterval] = []

    func wait(_ interval: TimeInterval) async throws {
        // NSLock.lock() is unavailable directly in async contexts; the
        // synchronous helper keeps the critical section suspension-free.
        record(interval)
    }

    private func record(_ interval: TimeInterval) {
        lock.lock()
        recorded.append(interval)
        lock.unlock()
    }

    var waits: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Route delivery recorder

/// Collects routes delivered by a `RouteDispatcher`.
final class RouteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ResolvedRoute] = []

    func append(_ route: ResolvedRoute) {
        lock.lock()
        recorded.append(route)
        lock.unlock()
    }

    var routes: [ResolvedRoute] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

// MARK: - Async polling helper

/// Polls an async condition until it holds or a bounded number of attempts is
/// exhausted (then fails the test). Never spins forever.
func waitUntil(
    _ description: String,
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: () async -> Bool
) async {
    for _ in 0..<2_000 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    XCTFail("Timed out waiting for: \(description)", file: file, line: line)
}

// MARK: - Message factory

func makeMessage(
    id: String,
    collapseID: String? = nil,
    sequence: UInt64? = nil,
    hint: String? = nil,
    deepLink: String? = nil
) -> RawPushMessage {
    RawPushMessage(
        messageID: id,
        collapseID: collapseID,
        sequence: sequence,
        interruptionHint: hint,
        title: "Title-\(id)",
        body: "Body-\(id)",
        deepLink: deepLink
    )
}
