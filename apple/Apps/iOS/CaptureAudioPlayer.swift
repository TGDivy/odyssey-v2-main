import AVFoundation
import Combine
import Foundation

enum CaptureAudioPlayerState: Equatable {
    case idle
    case loading
    case playing
    case paused
    case finished
    case failed(String)
}

@MainActor
final class CaptureAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var state: CaptureAudioPlayerState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func beginLoading() {
        stop()
        state = .loading
    }

    func playVerifiedContent(at url: URL) {
        guard state == .loading, url.isFileURL else {
            fail("The local voice capture could not be opened safely.")
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay(),
                  player.duration.isFinite,
                  player.duration > 0,
                  player.play()
            else {
                throw CaptureAudioPlayerError.playbackUnavailable
            }
            self.player = player
            duration = player.duration
            elapsed = 0
            state = .playing
            startProgressUpdates()
        } catch {
            fail("The local voice capture could not be played.")
        }
    }

    func pause() {
        guard state == .playing, let player else { return }
        player.pause()
        elapsed = player.currentTime
        progressTask?.cancel()
        progressTask = nil
        state = .paused
    }

    func resume() {
        guard state == .paused, let player else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            guard player.play() else {
                throw CaptureAudioPlayerError.playbackUnavailable
            }
            state = .playing
            startProgressUpdates()
        } catch {
            fail("The local voice capture could not resume playback.")
        }
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        elapsed = 0
        duration = 0
        state = .idle
        deactivateAudioSession()
    }

    func fail(_ message: String) {
        stop()
        state = .failed(message)
    }

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self] in
            self?.finish(player: player, successfully: flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error _: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.handleDecodeFailure(player: player)
        }
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self,
                      self.state == .playing,
                      let player = self.player
                else { return }
                self.elapsed = min(player.currentTime, self.duration)
            }
        }
    }

    private func finish(player: AVAudioPlayer, successfully: Bool) {
        guard self.player === player else { return }
        progressTask?.cancel()
        progressTask = nil
        elapsed = duration
        self.player = nil
        deactivateAudioSession()
        state = successfully
            ? .finished
            : .failed("The local voice capture ended unexpectedly.")
    }

    private func handleDecodeFailure(player: AVAudioPlayer) {
        guard self.player === player else { return }
        fail("The local voice capture could not be decoded.")
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }
}

private enum CaptureAudioPlayerError: Error {
    case playbackUnavailable
}
