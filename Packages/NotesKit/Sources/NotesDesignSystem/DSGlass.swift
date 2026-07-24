import ClassMateTheme
import SwiftUI

/// The app's single entry point to Liquid Glass.
///
/// HIG layering rule, enforced by convention here: glass is for the FUNCTIONAL
/// layer only — toolbars, the floating palette, popovers, sidebars. Content
/// (canvas, paper, covers) never calls this.
///
/// Honors Reduce Transparency by swapping glass for an opaque raised surface;
/// the system glass intensity slider is respected automatically by
/// `.glassEffect` itself.
public struct DSGlassModifier<S: Shape>: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.theme) private var theme

    let shape: S
    let interactive: Bool

    @ViewBuilder
    public func body(content: Content) -> some View {
        if reduceTransparency {
            content
                .background(theme.surfaceRaised.color, in: shape)
                .overlay(shape.stroke(theme.separator.color, lineWidth: 0.5))
        } else {
            content.glassEffect(glass, in: shape)
        }
    }

    private var glass: Glass {
        let tinted = Glass.regular.tint(theme.glassTint.color)
        return interactive ? tinted.interactive() : tinted
    }
}

extension View {
    /// Themed glass for functional-layer chrome.
    public func dsGlass(
        in shape: some Shape = Capsule(),
        interactive: Bool = false
    ) -> some View {
        modifier(DSGlassModifier(shape: shape, interactive: interactive))
    }
}

/// A round glass icon button for toolbars and the floating palette.
public struct DSGlassIconButton: View {
    @Environment(\.theme) private var theme

    let systemImage: String
    let label: String
    let isActive: Bool
    let action: () -> Void

    public init(
        _ label: String,
        systemImage: String,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.systemImage = systemImage
        self.isActive = isActive
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isActive ? theme.accent.color : theme.ink.color)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .background {
            if isActive {
                Circle().fill(theme.accentMuted.color)
            }
        }
    }
}
