import Foundation

/// How long a deleted notebook is kept before it is really gone.
///
/// Pure arithmetic, deliberately kept away from the repository so the one
/// question that matters — "is this notebook about to be destroyed?" — can be
/// tested without a database, a clock or a document package.
public enum TrashPolicy {
    /// The grace period. Thirty days is the convention people already know from
    /// Photos, Files and Notes, so nobody has to learn a new one to feel safe.
    public static let retention: TimeInterval = 30 * 24 * 60 * 60

    /// Whether something deleted at `deletedAt` has run out of grace.
    ///
    /// A notebook with no deletion date is live, and a live notebook is never
    /// expired — the caller must not have to remember to check that itself.
    public static func isExpired(
        deletedAt: Date?, now: Date = .now, retention: TimeInterval = TrashPolicy.retention
    ) -> Bool {
        guard let deletedAt else { return false }
        return now.timeIntervalSince(deletedAt) >= retention
    }

    /// Whole days left before it is purged, floored at zero. What the trash row
    /// says under the title.
    public static func daysRemaining(
        deletedAt: Date?, now: Date = .now, retention: TimeInterval = TrashPolicy.retention
    ) -> Int {
        guard let deletedAt else { return 0 }
        let left = retention - now.timeIntervalSince(deletedAt)
        guard left > 0 else { return 0 }
        return Int((left / 86_400).rounded(.up))
    }

    /// How the countdown reads in the trash list.
    public static func expiryLabel(
        deletedAt: Date?, now: Date = .now, retention: TimeInterval = TrashPolicy.retention
    ) -> String {
        let days = daysRemaining(deletedAt: deletedAt, now: now, retention: retention)
        switch days {
        case 0: return "Deleting today"
        case 1: return "1 day left"
        default: return "\(days) days left"
        }
    }
}
