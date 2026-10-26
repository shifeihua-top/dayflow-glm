//
//  IntrusionAudioRecorder.swift
//  Dayflow
//
//  Event-triggered microphone recording for the webcam observation module:
//  captures ambient audio only while an intrusion condition (peeking /
//  stranger at the keyboard) is active, straight to an .m4a file.
//

import AVFoundation

final class IntrusionAudioRecorder {
  private let engine = AVAudioEngine()
  private var file: AVAudioFile?
  var isRecording: Bool { engine.isRunning }

  static var micPermissionGranted: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  static func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
    AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
  }

  func start(to url: URL) -> Bool {
    guard !engine.isRunning else { return true }
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0 else { return false }
    guard
      let audioFile = try? AVAudioFile(
        forWriting: url,
        settings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC,
          AVSampleRateKey: format.sampleRate,
          AVNumberOfChannelsKey: 1,
          AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        ])
    else { return false }

    file = audioFile
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      guard let file = self?.file else { return }
      try? file.write(from: buffer)
    }
    do {
      engine.prepare()
      try engine.start()
      return true
    } catch {
      input.removeTap(onBus: 0)
      file = nil
      return false
    }
  }

  /// Stops and returns the file URL when anything was recorded.
  @discardableResult
  func stop() -> URL? {
    guard engine.isRunning else { return nil }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    defer { file = nil }
    guard let audioFile = file else { return nil }
    return audioFile.url
  }
}
