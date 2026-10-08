import Foundation
import Synchronization

/// The ordering authority for page ink on its way to disk.
///
/// Saving a page has always been fire-and-forget: a debounced save encodes the
/// drawing off the main actor and then hops to `DocumentStore`, while leaving
/// the editor (or backgrounding the app) flushes synchronously and hops there
/// too. Nothing ordered those hops. An older save still encoding when a flush
/// landed would write AFTER it — putting back ink the user had just erased, or
/// dropping the stroke written last. And a page reopened before its flush
/// reached the actor read the previous file, showed it, and then saved that
/// stale copy over the newer one for good.
///
/// So every save takes a `Stamp` at the moment its SNAPSHOT is taken — not when
/// it happens to arrive — and:
/// - the store refuses any write older than the newest one already written;
/// - the newest staged bytes are readable before they reach disk, so a page
///   that loads in the gap sees exactly what the user last saw.
///
/// Synchronous and lock-protected rather than an actor, because the canvas has
/// to stamp and stage from the main actor in the same turn it reads the drawing.
public final class PageInkJournal: Sendable {
    public struct Stamp: Comparable, Sendable {
        let value: UInt64
        public static func < (lhs: Stamp, rhs: Stamp) -> Bool { lhs.value < rhs.value }
    }

    private struct State {
        var counter: UInt64 = 0
        var staged: [UUID: (stamp: Stamp, data: Data)] = [:]
        var written: [UUID: Stamp] = [:]
    }

    private let state = Mutex(State())

    public init() {}

    /// A stamp later than every stamp handed out before it. Take it at the
    /// moment the drawing is read.
    public func stamp() -> Stamp {
        state.withLock { state in
            state.counter &+= 1
            return Stamp(value: state.counter)
        }
    }

    /// Holds `data` as the page's newest ink until it is written. A stamp older
    /// than what is already staged is ignored.
    public func stage(_ data: Data, page: UUID, stamp: Stamp) {
        state.withLock { state in
            if let existing = state.staged[page], existing.stamp > stamp { return }
            if let written = state.written[page], written > stamp { return }
            state.staged[page] = (stamp, data)
        }
    }

    /// The newest ink not yet on disk, if any.
    public func pending(page: UUID) -> Data? {
        state.withLock { $0.staged[page]?.data }
    }

    /// Whether a write stamped `stamp` may go to disk: false once anything newer
    /// has been written.
    func admits(_ stamp: Stamp, page: UUID) -> Bool {
        state.withLock { state in
            guard let written = state.written[page] else { return true }
            return stamp > written
        }
    }

    /// Records that `stamp` is on disk, and lets go of the staged bytes if they
    /// are exactly what was written.
    func settle(page: UUID, stamp: Stamp) {
        state.withLock { state in
            if let written = state.written[page], written > stamp { return }
            state.written[page] = stamp
            if let staged = state.staged[page], staged.stamp <= stamp {
                state.staged[page] = nil
            }
        }
    }

    /// A deleted page has nothing pending and nothing to come back to.
    func forget(page: UUID) {
        state.withLock { state in
            state.staged[page] = nil
        }
    }
}
