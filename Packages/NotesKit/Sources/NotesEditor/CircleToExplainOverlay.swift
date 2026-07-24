import ClassMateTheme
import SwiftUI

/// When explain-mode is on, drag a box around a paragraph or photo. On release
/// the selected page rect (in view space) is reported so the editor can crop +
/// OCR that region and hand it to NOVA.
struct CircleToExplainOverlay: View {
    @Environment(\.theme) private var theme

    let onSelect: (CGRect) -> Void

    @State private var startPoint: CGPoint?
    @State private var currentRect: CGRect = .zero

    var body: some View {
        GeometryReader { _ in
            ZStack {
                theme.accent.withAlpha(0.05).color
                if currentRect != .zero {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.accent.color, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(theme.accent.withAlpha(0.10).color)
                        )
                        .frame(width: currentRect.width, height: currentRect.height)
                        .position(x: currentRect.midX, y: currentRect.midY)
                }
                VStack {
                    Label("Draw a box around what NOVA should explain", systemImage: "lasso")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(theme.accent.color, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { value in
                        let origin = startPoint ?? value.startLocation
                        startPoint = origin
                        currentRect = CGRect(
                            x: min(origin.x, value.location.x),
                            y: min(origin.y, value.location.y),
                            width: abs(value.location.x - origin.x),
                            height: abs(value.location.y - origin.y)
                        )
                    }
                    .onEnded { _ in
                        if currentRect.width > 24, currentRect.height > 24 {
                            onSelect(currentRect)
                        }
                        startPoint = nil
                        currentRect = .zero
                    }
            )
        }
    }
}
