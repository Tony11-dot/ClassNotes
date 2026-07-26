import AVFoundation
import ClassMateTheme
import NotesDesignSystem
import NotesServices
import SwiftUI

/// Records a voice note and hands back the file + duration to drop on the page.
///
/// Tapping the mic opens this already recording, hands-free ("locked") — no
/// second tap, no press-and-hold. It requests microphone permission up front
/// and, if that's denied, says so with a shortcut to Settings instead of
/// silently doing nothing.
struct VoiceRecorderSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    let onSave: (URL, TimeInterval) -> Void

    @State private var recorder = AudioRecorderModel()
    @State private var fileURL: URL?
    @State private var permissionDenied = false
    @State private var startFailed = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                if permissionDenied || startFailed {
                    deniedView
                } else {
                    recordingView
                }
                Spacer()
                controls
            }
            .frame(maxWidth: .infinity)
            .background(theme.surface.color)
            .navigationTitle("Voice note")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await begin() }
    }

    // MARK: - Recording UI

    private var recordingView: some View {
        VStack(spacing: 22) {
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
            if recorder.isRecording {
                Label("Hands-free — recording locked", systemImage: "lock.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(theme.inkSecondary.color)
            }
        }
    }

    private var deniedView: some View {
        VStack(spacing: 14) {
            Image(systemName: "mic.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(theme.inkSecondary.color)
            Text(permissionDenied ? "Microphone access is off" : "Couldn't start recording")
                .font(.headline)
                .foregroundStyle(theme.ink.color)
            Text(permissionDenied
                 ? "Turn on the microphone for ClassNotes in Settings to record voice notes."
                 : "Something went wrong starting the recorder. Try again.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.inkSecondary.color)
                .padding(.horizontal, 40)
            if permissionDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings", destination: url)
                    .font(.headline)
                    .foregroundStyle(theme.accent.color)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                recorder.cancel()
                dismiss()
            } label: {
                Label("Cancel", systemImage: "xmark").font(.headline)
            }
            .tint(theme.inkSecondary.color)

            if recorder.isRecording {
                Button { stop() } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(theme.accent.color)
                }
                .accessibilityLabel("Stop and save")
            }
        }
        .padding(.bottom, 40)
    }

    // MARK: - Lifecycle

    /// Ask for the mic once, then start recording immediately (hands-free).
    private func begin() async {
        guard !recorder.isRecording else { return }
        let granted = await AVAudioApplication.requestRecordPermission()
        guard granted else {
            permissionDenied = true
            return
        }
        start()
    }

    private func start() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        fileURL = url
        do {
            try recorder.start(to: url)
        } catch {
            startFailed = true
        }
    }

    private func stop() {
        let duration = recorder.stop()
        if let url = fileURL, let duration {
            onSave(url, duration)
        }
        dismiss()
    }
}
