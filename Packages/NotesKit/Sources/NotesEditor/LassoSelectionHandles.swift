import ClassMateTheme
import NotesDesignSystem
import NotesModels
import SwiftUI
import UIKit

/// The selection's turn handle and its colour picker (D-008).
extension LassoSelectionView {

    /// Drag it round the selection to turn everything caught. It settles on
    /// every 15° (a tap in the hand as it lands), because square is what a
    /// hand is usually aiming for and lands a degree or two off.
    var rotateHandle: some View {
        Image(systemName: "arrow.clockwise")
            .font(.dsSystem(size: 12, weight: .bold))
            .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
            .frame(width: 26, height: 26)
            .background(theme.accent.color, in: Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { value in
                        requestPreview()
                        let raw = SelectionRotation.turn(
                            about: liveCentre, from: value.startLocation, to: value.location
                        )
                        let (angle, settled) = SelectionRotation.detented(raw)
                        if settled, !turnSettled {
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                        turnSettled = settled
                        turn = angle
                    }
                    .onEnded { _ in
                        // Held until the turn lands (`settle`), like the drag.
                        guard abs(turn) > 0.002 else {
                            settle()
                            return
                        }
                        onRotate(turn)
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Rotate selection")
            .accessibilityHint("Drag around the selection to turn it.")
            .accessibilityAdjustableAction { direction in
                let step = CGFloat(SelectionRotation.detentStep * .pi / 180)
                switch direction {
                case .increment: onRotate(step)
                case .decrement: onRotate(-step)
                @unknown default: break
                }
            }
    }

    /// The pen palette, plus the wheel for anything else. Picking a colour
    /// paints the selection and closes the picker.
    var colorPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Colour")
                .font(.dsSubheadline.weight(.semibold))
                .foregroundStyle(theme.ink.color)
            ColorSwatchRow(
                swatches: palette,
                selection: Binding(
                    get: { nil },
                    set: { hex in
                        guard let hex else { return }
                        onRecolor(hex)
                        showColors = false
                    }
                )
            )
            Text("Photos and files keep their own colours.")
                .font(.dsCaption)
                .foregroundStyle(theme.inkSecondary.color)
            if holdsInk {
                Divider()
                Text("Thickness")
                    .font(.dsSubheadline.weight(.semibold))
                    .foregroundStyle(theme.ink.color)
                HStack(spacing: 10) {
                    thicknessButton("Thinner", systemImage: "minus", factor: Self.thinner)
                    thicknessButton("Thicker", systemImage: "plus", factor: Self.thicker)
                }
                Text("Each press changes the ink you circled; Undo takes it back.")
                    .font(.dsCaption)
                    .foregroundStyle(theme.inkSecondary.color)
            }
        }
        .padding(16)
        .frame(width: 320)
        .presentationCompactAdaptation(.popover)
    }

    /// One press of Thicker, and the step Thinner takes back exactly.
    static let thicker: CGFloat = 1.3
    static let thinner: CGFloat = 1 / 1.3

    /// Stays open: thickness is judged by eye, a press at a time.
    private func thicknessButton(_ title: String, systemImage: String, factor: CGFloat) -> some View {
        Button {
            onRethicken(factor)
            UISelectionFeedbackGenerator().selectionChanged()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.dsSubheadline.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(theme.surfaceRaised.color, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .foregroundStyle(theme.ink.color)
        }
        .buttonStyle(.plain)
    }
}
