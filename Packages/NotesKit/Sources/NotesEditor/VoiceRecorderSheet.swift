import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Records a voice note and hands back the file + duration to drop on the page.
struct VoiceRecorderSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onSave: (URL, TimeInterval) -> Void

    @State private var recorder = AudioRecorderModel()
    @State private var fileURL: URL?

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                ZStack {
                    Circle()
                        .fill(theme.accent.withAlpha(recorder.isRecording ? 0.25 : 0.12).color)
                        .frame(width: 140, height: 140)
                        .scaleEffect(1 + recorder.level * 0.3)
                        .animation(.easeOut(duration: 0.08), value: recorder.level)
                    Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(theme.accent.color)
                }
                Text(VoiceBubbleView.timeString(recorder.elapsed))
                    .font(.system(size: 34, weight: .bold).monospacedDigit())
                    .foregroundStyle(theme.ink.color)
                Spacer()
                HStack(spacing: 40) {
                    Button {
                        recorder.cancel()
                        dismiss()
                    } label: {
                        Label("Cancel", systemImage: "xmark").font(.headline)
                    }
                    .tint(theme.inkSecondary.color)

                    Button {
                        if recorder.isRecording {
                            stop()
                        } else {
                            start()
                        }
                    } label: {
                        Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle")
                            .font(.system(size: 64))
                            .foregroundStyle(theme.accent.color)
                    }
                }
                .padding(.bottom, 40)
            }
            .frame(maxWidth: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Voice note")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        fileURL = url
        try? recorder.start(to: url)
    }

    private func stop() {
        let duration = recorder.stop()
        if let url = fileURL, let duration {
            onSave(url, duration)
        }
        dismiss()
    }
}
