import AVFoundation
import Combine
import Foundation
import UIKit

enum VoiceCaptureRecorderState: Equatable {
    case idle
    case requestingPermission
    case recording
    case ready
    case permissionDenied
    case failed(String)
}

@MainActor
final class VoiceCaptureRecorder: NSObject, ObservableObject {
    static let maximumDuration: TimeInterval = 5 * 60

    @Published private(set) var state: VoiceCaptureRecorderState = .idle
    @Published private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var elapsedTask: Task<Void, Never>?
    private var startedAt: Date?
    private var permissionRequestID: UUID?

    var isRecording: Bool {
        state == .recording
    }

    var preparedRecordingURL: URL? {
        state == .ready ? recordingURL : nil
    }

    func start() async {
        guard state != .requestingPermission, state != .recording else { return }
        discardRecording()
        let requestID = UUID()
        permissionRequestID = requestID
        state = .requestingPermission
        let permission = AVAudioApplication.shared.recordPermission
        let granted: Bool
        switch permission {
        case .granted:
            granted = true
        case .denied:
            granted = false
        case .undetermined:
            granted = await AVAudioApplication.requestRecordPermission()
        @unknown default:
            granted = false
        }
        guard permissionRequestID == requestID,
              state == .requestingPermission
        else { return }
        permissionRequestID = nil
        guard granted else {
            state = .permissionDenied
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            state = .idle
            return
        }
        do {
            try beginRecording()
        } catch {
            deactivateAudioSession()
            discardRecording()
            state = .failed("Voice recording could not start safely.")
        }
    }

    func stop() {
        guard state == .recording else { return }
        recorder?.stop()
    }

    func cancel() {
        let wasRecording = state == .recording
        permissionRequestID = nil
        state = .idle
        if wasRecording {
            recorder?.stop()
        }
        discardRecording()
    }

    func completeSave() {
        discardRecording()
        state = .idle
    }

    func stopForBackgrounding() {
        if state == .recording {
            stop()
        }
    }

    func refreshPermissionState() {
        guard state == .permissionDenied,
              AVAudioApplication.shared.recordPermission != .denied
        else { return }
        state = .idle
    }

    nonisolated func audioRecorderDidFinishRecording(
        _ recorder: AVAudioRecorder,
        successfully flag: Bool
    ) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            self?.finishRecording(at: url, successfully: flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(
        _ recorder: AVAudioRecorder,
        error _: Error?
    ) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            self?.failRecording(at: url)
        }
    }

    private func beginRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "OdysseyVoiceCapture",
            isDirectory: true
        )
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "voice-\(UUID().uuidString).m4a",
            isDirectory: false
        )
        recordingURL = url
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.prepareToRecord() else {
            throw VoiceCaptureRecorderError.preparationFailed
        }
        try applyTemporaryFileProtection(to: url)
        guard recorder.record(forDuration: Self.maximumDuration) else {
            throw VoiceCaptureRecorderError.recordingFailed
        }
        self.recorder = recorder
        recordingURL = url
        elapsed = 0
        startedAt = Date()
        state = .recording
        startElapsedUpdates()
    }

    private func startElapsedUpdates() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self,
                      self.state == .recording,
                      let startedAt = self.startedAt
                else { return }
                self.elapsed = min(Date().timeIntervalSince(startedAt), Self.maximumDuration)
            }
        }
    }

    private func finishRecording(at url: URL, successfully: Bool) {
        guard state == .recording, recorder?.url == url else { return }
        elapsedTask?.cancel()
        elapsedTask = nil
        elapsed = min(recorder?.currentTime ?? elapsed, Self.maximumDuration)
        recorder = nil
        startedAt = nil
        deactivateAudioSession()
        guard successfully,
              let recordingURL,
              FileManager.default.fileExists(atPath: recordingURL.path)
        else {
            discardRecording()
            state = .failed("Voice recording did not finish safely.")
            return
        }
        state = .ready
    }

    private func failRecording(at url: URL) {
        guard state == .recording, recorder?.url == url else { return }
        elapsedTask?.cancel()
        elapsedTask = nil
        recorder?.stop()
        recorder = nil
        startedAt = nil
        deactivateAudioSession()
        discardRecording()
        state = .failed("Voice recording could not be encoded safely.")
    }

    private func discardRecording() {
        elapsedTask?.cancel()
        elapsedTask = nil
        recorder = nil
        startedAt = nil
        elapsed = 0
        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }
        recordingURL = nil
        deactivateAudioSession()
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func applyTemporaryFileProtection(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }
}

private enum VoiceCaptureRecorderError: Error {
    case preparationFailed
    case recordingFailed
}
