import Foundation
import os

/// Signposts for the operations the quality bar puts numbers on: opening a
/// notebook, loading and saving a page, rendering, searching, importing.
///
/// They cost next to nothing when nobody is recording, and they are what makes
/// "it feels fast" measurable: run the app under Instruments (Points of
/// Interest / os_signpost) on a device and every interval below shows up with
/// its duration. Names are static strings so nothing about a user's notes ever
/// reaches a trace.
public enum Perf {
    public static let signposter = OSSignposter(
        subsystem: "app.classnotes", category: .pointsOfInterest
    )

    /// Times `work` as one signposted interval.
    @discardableResult
    public static func measure<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try work()
    }

    /// Async variant of `measure`.
    @discardableResult
    public static func measure<T>(
        _ name: StaticString, _ work: () async throws -> T
    ) async rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try await work()
    }

    /// A point event — something worth seeing on the timeline that has no
    /// duration (a recovery, a refused write).
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    /// Starts an interval that ends somewhere else (a notebook opening ends when
    /// its first page has ink on screen).
    public static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }
}
