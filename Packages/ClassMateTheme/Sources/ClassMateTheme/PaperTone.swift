import Foundation

/// Warm / neutral / cool cast applied to the page background, independent of
/// the theme. Implemented as a subtle fixed-tint composite over the theme's
/// paper color so it works on light and dark papers alike.
public enum PaperTone: String, CaseIterable, Sendable, Codable {
    case warm
    case neutral
    case cool

    public var displayName: String {
        switch self {
        case .warm: "Warm"
        case .neutral: "Neutral"
        case .cool: "Cool"
        }
    }

    /// Strength of the cast — small on purpose; paper must stay paper.
    private static let castAlpha: Double = 0.08

    public func apply(to paper: ThemeColor) -> ThemeColor {
        switch self {
        case .neutral:
            paper
        case .warm:
            ThemeColor(red: 1.0, green: 0.71, blue: 0.37, alpha: Self.castAlpha)
                .composited(over: paper)
        case .cool:
            ThemeColor(red: 0.37, green: 0.66, blue: 1.0, alpha: Self.castAlpha)
                .composited(over: paper)
        }
    }
}
