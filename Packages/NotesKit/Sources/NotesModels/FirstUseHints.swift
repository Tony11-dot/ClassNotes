import Foundation

/// One line of teaching, shown the FIRST time a feature is reached and never
/// again. The app has no tutorial: someone who opens it should be writing in a
/// second. What isn't obvious is taught at the moment it matters — the first
/// time the lasso is picked up, not on a screen before any notebook exists.
public enum FirstUseHint: String, CaseIterable, Sendable {
    case lasso
    case tape
    case fill
    case text
    case ruledLine
    case hand
    case nova
    case snip
    case pageManager

    public var message: String {
        switch self {
        case .lasso: "Draw around anything to select it."
        case .tape: "Lay tape over anything to hide it. Tap the tape to peek underneath."
        case .fill: "Tap inside a shape to fill it with colour."
        case .text: "Tap where you want to type."
        case .ruledLine: "Tap the page to rule a straight line through that spot."
        case .hand: "Drag and resize photos, text and files. The pencil won't draw."
        case .nova: "Ask NOVA about anything in your notes."
        case .snip: "Drag a box around anything you want NOVA to explain."
        case .pageManager: "Drag a page to reorder it. Press and hold for more."
        }
    }
}

/// Which hints this device has shown. Per device on purpose: a second iPad is
/// somewhere the user may well not have found the lasso yet.
public struct FirstUseHints {
    static let key = "firstUseHints.seen.v1"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var seen: Set<FirstUseHint> {
        Set((defaults.stringArray(forKey: Self.key) ?? []).compactMap(FirstUseHint.init(rawValue:)))
    }

    /// True exactly once per hint: the first call shows it and records that
    /// it was shown, every later call says no. Recorded on SHOWING, not on
    /// dismissal, so a hint the user never touched doesn't nag them again.
    public func claim(_ hint: FirstUseHint) -> Bool {
        var current = seen
        guard current.insert(hint).inserted else { return false }
        defaults.set(current.map(\.rawValue).sorted(), forKey: Self.key)
        return true
    }

    /// Every hint shows again (Settings → Show tips again).
    public func reset() {
        defaults.removeObject(forKey: Self.key)
    }
}
