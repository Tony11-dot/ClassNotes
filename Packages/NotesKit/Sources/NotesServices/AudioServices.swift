import AVFoundation
import Foundation
import Observation

/// Records a voice note to an `.m4a` file. UI drops a ClassMate-style voice
/// bubble onto the page pointing at the saved file.
@MainActor
@Observable
public final class AudioRecorderModel {
    public private(set) var isRecording = false
    public private(set) var elapsed: TimeInterval = 0
    /// Live 0...1 level for the waveform while recording.
    public private(set) var level: Double = 0

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    public init() {}

    public func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.record()
        self.recorder = recorder
        isRecording = true
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// Stops and returns the recorded duration (seconds), or nil if nothing.
    @discardableResult
    public func stop() -> TimeInterval? {
        timer?.invalidate()
        timer = nil
        guard let recorder else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return duration > 0.2 ? duration : nil
    }

    public func cancel() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        isRecording = false
    }

    private func tick() {
        guard let recorder else { return }
        recorder.updateMeters()
        elapsed = recorder.currentTime
        // -160 dB (silence) ... 0 dB (max) → 0...1
        let power = recorder.averagePower(forChannel: 0)
        level = Double(max(0, (power + 55) / 55))
    }
}

/// Plays a saved voice note and reports progress for the bubble scrubber.
@MainActor
@Observable
public final class AudioPlayerModel: NSObject, AVAudioPlayerDelegate {
    public private(set) var isPlaying = false
    public private(set) var progress: Double = 0
    public private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    public override init() { super.init() }

    public func toggle(url: URL) {
        if isPlaying {
            pause()
        } else {
            play(url: url)
        }
    }

    public func play(url: URL) {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            duration = player.duration
            isPlaying = true
            timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
        } catch {
            isPlaying = false
        }
    }

    public func pause() {
        player?.pause()
        isPlaying = false
        timer?.invalidate()
    }

    public func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = fraction * player.duration
        progress = fraction
    }

    private func tick() {
        guard let player else { return }
        progress = player.duration > 0 ? player.currentTime / player.duration : 0
    }

    public nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            progress = 0
            timer?.invalidate()
        }
    }
}
