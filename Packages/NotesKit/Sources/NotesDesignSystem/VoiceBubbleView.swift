import ClassMateTheme
import NotesServices
import SwiftUI

/// A ClassMate-style voice-message bubble placed on the page: play/pause glyph,
/// deterministic waveform (seeded so it's stable), and duration. Tap to play.
public struct VoiceBubbleView: View {
    @Environment(\.theme) private var theme
    @State private var player = AudioPlayerModel()

    let url: URL
    let duration: TimeInterval
    let seed: Int

    public init(url: URL, duration: TimeInterval, seed: Int) {
        self.url = url
        self.duration = duration
        self.seed = seed
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button {
                player.toggle(url: url)
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.dsSystem(size: 20, weight: .semibold))
                    .foregroundStyle(theme.contrastingInk(on: theme.accent).color)
                    .frame(width: 30, height: 36)
            }
            .buttonStyle(.plain)

            Waveform(seed: seed, progress: player.isPlaying ? player.progress : 0)
                .frame(height: 26)
                .frame(minWidth: 90)

            Text(Self.timeString(duration))
                .font(.dsCaption2.monospacedDigit())
                .foregroundStyle(theme.contrastingInk(on: theme.accent).color.opacity(0.85))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(theme.accent.color, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Voice note, \(Int(duration)) seconds")
    }

    public static func timeString(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Deterministic pseudo-random waveform bars, seeded so a given clip always
/// looks the same. Played portion is brighter.
struct Waveform: View {
    @Environment(\.theme) private var theme
    let seed: Int
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            let ink = theme.contrastingInk(on: theme.accent).color
            let barCount = max(12, Int(geo.size.width / 4.6))
            var rng = SplitMix64(seed: UInt64(bitPattern: Int64(seed)) | 1)
            let heights = (0..<barCount).map { _ in 0.25 + rng.nextUnit() * 0.75 }
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    let played = Double(index) / Double(barCount) <= progress
                    Capsule()
                        .fill(ink.opacity(played ? 0.95 : 0.4))
                        .frame(width: 2.6, height: geo.size.height * heights[index])
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }
}
