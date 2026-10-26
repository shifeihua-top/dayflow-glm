//
//  WebcamObserver.swift
//  Dayflow
//
//  Experimental opt-in camera observation module.
//
//  Privacy contract:
//  - Frames live ONLY in memory, in a ~20 minute ring buffer, and are never
//    written to disk or included in any log.
//  - Presence detection runs on-device via the Vision framework (free, no LLM).
//  - LLM access to frames happens only through the transcription pipeline,
//    which pulls the ring-buffer frame nearest in time to each sampled
//    screenshot, and only when the user enables it.
//

import AVFoundation
import AppKit
import Combine
import CoreMedia
import Vision

final class WebcamObserver: NSObject, @unchecked Sendable {

  static let shared = WebcamObserver()

  static let enabledKey = "webcamObservationEnabled"
  static let sendToLLMKey = "webcamSendFramesToLLM"
  static let intervalKey = "webcamCaptureIntervalSeconds"
  static let retentionMinutes = 20
  static let presenceRetentionMinutes = 60
  /// Frames to skip after the session starts so auto-exposure settles.
  static let warmupFrames = 45

  struct SnapshotContext {
    /// Base64 JPEG of the webcam frame nearest in time, nil when the LLM-frame
    /// toggle is off or no frame is close enough to the screenshot.
    let frameBase64: String?
    /// Plain-text presence summary around the screenshot's timestamp.
    let presenceSummary: String?
  }

  private let q = DispatchQueue(label: "dayflow.webcam.observer")
  private let frameQueue = DispatchQueue(label: "dayflow.webcam.frames")

  private var session: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var captureTimer: DispatchSourceTimer?
  private var cancellables: Set<AnyCancellable> = []
  private var runtimeErrorObserver: NSObjectProtocol?

  // State guarded by `q`.
  private var running = false
  private var permissionDenied = false
  private var lastError: String?
  private var frames: [(date: Date, base64: String)] = []
  private var presence: [(date: Date, present: Bool)] = []

  // State guarded by `frameQueue`.
  private var frameCount = 0
  private var captureRequested = false
  private var freshImage: CGImage?
  private let frameSemaphore = DispatchSemaphore(value: 0)

  private var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: Self.enabledKey)
  }

  private var sendFramesToLLM: Bool {
    UserDefaults.standard.object(forKey: Self.sendToLLMKey) == nil
      ? true
      : UserDefaults.standard.bool(forKey: Self.sendToLLMKey)
  }

  private var interval: TimeInterval {
    let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
    return stored >= 15 ? stored : 60
  }

  static var isConfigured: Bool {
    UserDefaults.standard.bool(forKey: enabledKey)
  }

  // MARK: - Lifecycle

  /// Called once at app launch. Starts observing when the module is enabled
  /// and follows the app-wide recording flag afterwards.
  @MainActor
  func bootstrap() {
    AppState.shared.$isRecording
      .receive(on: DispatchQueue.main)
      .sink { [weak self] recording in
        guard let self else { return }
        if recording && self.isEnabled {
          self.start()
        } else {
          self.stop(reason: recording ? nil : "recording disabled")
        }
      }
      .store(in: &cancellables)
  }

  func setEnabled(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
    q.async { [weak self] in
      guard let self else { return }
      if enabled, AppState.shared.isRecording {
        self.startLocked()
      } else if !enabled {
        self.stopLocked(reason: "disabled in settings")
      }
    }
  }

  func setSendFramesToLLM(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.sendToLLMKey)
  }

  private func start() {
    q.async { [weak self] in self?.startLocked() }
  }

  private func stop(reason: String?) {
    q.async { [weak self] in self?.stopLocked(reason: reason) }
  }

  private func startLocked() {
    guard !running else { return }
    guard AVCaptureDevice.default(for: .video) != nil else {
      lastError = "未检测到摄像头"
      return
    }
    running = true
    lastError = nil

    AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
      self?.q.async { [weak self] in
        guard let self else { return }
        guard granted else {
          self.permissionDenied = true
          self.lastError = "摄像头权限被拒绝"
          self.running = false
          return
        }
        self.buildAndStartSessionLocked()
      }
    }
  }

  private func buildAndStartSessionLocked() {
    guard running else { return }
    let session = AVCaptureSession()
    session.sessionPreset = .vga640x480
    guard
      let device = AVCaptureDevice.default(for: .video),
      let input = try? AVCaptureDeviceInput(device: device),
      session.canAddInput(input)
    else {
      lastError = "无法打开摄像头"
      running = false
      return
    }
    session.addInput(input)

    let output = AVCaptureVideoDataOutput()
    output.videoSettings = [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ]
    output.alwaysDiscardsLateVideoFrames = true
    output.setSampleBufferDelegate(self, queue: frameQueue)
    guard session.canAddOutput(output) else {
      lastError = "无法配置摄像头输出"
      running = false
      return
    }
    session.addOutput(output)

    frameQueue.async { [weak self] in
      self?.frameCount = 0
      self?.captureRequested = false
      self?.freshImage = nil
    }

    session.startRunning()
    self.session = session
    self.videoOutput = output

    runtimeErrorObserver = NotificationCenter.default.addObserver(
      forName: .AVCaptureSessionRuntimeError, object: session, queue: nil
    ) { [weak self] note in
      let err = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
      self?.q.async { [weak self] in
        self?.lastError = "摄像头错误：\(err?.localizedDescription ?? "unknown")"
      }
    }

    let timer = DispatchSource.makeTimerSource(queue: q)
    timer.schedule(deadline: .now() + 3, repeating: interval)
    timer.setEventHandler { [weak self] in self?.captureTick() }
    timer.resume()
    captureTimer = timer
  }

  private func stopLocked(reason: String?) {
    guard running || session != nil else { return }
    running = false
    captureTimer?.cancel()
    captureTimer = nil
    if let observer = runtimeErrorObserver {
      NotificationCenter.default.removeObserver(observer)
      runtimeErrorObserver = nil
    }
    session?.stopRunning()
    session = nil
    videoOutput = nil
    frameQueue.async { [weak self] in
      // Privacy: drop every retained frame as soon as observation stops.
      self?.freshImage = nil
      self?.captureRequested = false
    }
    frames.removeAll()
    presence.removeAll()
    if let reason { lastError = reason }
  }

  // MARK: - Capture tick (runs on `q`)

  private func captureTick() {
    guard running else { return }
    frameQueue.async { [weak self] in
      guard let self else { return }
      self.captureRequested = true
    }
    // frameQueue signals after converting one fresh frame (or times out).
    _ = frameSemaphore.wait(timeout: .now() + 4)
    frameQueue.async { [weak self] in
      guard let self else { return }
      guard let image = self.freshImage else { return }
      self.freshImage = nil

      let now = Date()
      let faceCount = Self.detectFaces(in: image)
      let base64 = self.sendFramesToLLM
        ? NSBitmapImageRep(cgImage: image)
          .representation(using: .jpeg, properties: [.compressionFactor: 0.8])?
          .base64EncodedString()
        : nil

      self.q.async { [weak self] in
        guard let self else { return }
        self.lastFaceCountInternal = faceCount
        if let base64 {
          self.frames.append((now, base64))
        }
        self.presence.append((now, faceCount > 0))
        self.trimRings(now: now)
      }
    }
  }

  private var lastFaceCountInternal = -1

  private func trimRings(now: Date) {
    let frameCutoff = now.addingTimeInterval(-TimeInterval(Self.retentionMinutes * 60))
    frames.removeAll { $0.date < frameCutoff }
    let presenceCutoff = now.addingTimeInterval(-TimeInterval(Self.presenceRetentionMinutes * 60))
    presence.removeAll { $0.date < presenceCutoff }
  }

  // MARK: - Frame delegate (runs on `frameQueue`)

  private func handleVideoFrame(_ sampleBuffer: CMSampleBuffer) {
    frameCount += 1
    guard frameCount >= Self.warmupFrames, captureRequested else { return }
    captureRequested = false
    guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    let ciImage = CIImage(cvPixelBuffer: pb)
    let context = CIContext()
    freshImage = context.createCGImage(ciImage, from: ciImage.extent)
    frameSemaphore.signal()
  }

  // MARK: - Vision presence detection

  private static func detectFaces(in image: CGImage) -> Int {
    for orientation in [.leftMirrored, .up] as [CGImagePropertyOrientation] {
      let handler = VNImageRequestHandler(cgImage: image, orientation: orientation)
      let request = VNDetectFaceRectanglesRequest()
      try? handler.perform([request])
      if let count = request.results?.count, count > 0 {
        return count
      }
    }
    return 0
  }

  // MARK: - Transcription integration

  /// Snapshot for a screenshot captured at `unixTimestamp`. Returns the frame
  /// nearest in time (±2 min) plus a presence summary for the surrounding
  /// 15 minutes. Cheap: no LLM, no disk, nothing leaves memory here.
  func contextForScreenshot(at unixTimestamp: Int) -> SnapshotContext? {
    guard isEnabled else { return nil }
    return q.sync { [weak self] () -> SnapshotContext? in
      guard let self else { return nil }
      let date = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))

      var frameBase64: String?
      if sendFramesToLLM,
        let nearest = self.frames.min(by: {
          abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }), abs(nearest.date.timeIntervalSince(date)) <= 120
      {
        frameBase64 = nearest.base64
      }

      var presenceSummary: String?
      if !self.presence.isEmpty {
        let windowStart = date.addingTimeInterval(-15 * 60)
        let window = self.presence.filter { $0.date >= windowStart && $0.date <= date }
        if !window.isEmpty {
          let presentCount = window.filter(\.present).count
          let ratio = Double(presentCount) / Double(window.count)
          let percent = Int((ratio * 100).rounded())
          let status =
            ratio > 0.9
            ? "全程在电脑前"
            : ratio > 0.4
              ? "大部分时间在电脑前（\(percent)%）"
              : ratio > 0.05
                ? "经常离开（在场仅 \(percent)%）"
                : "基本不在电脑前"
          presenceSummary = "摄像头观察（近15分钟）：\(status)"
        }
      }

      if frameBase64 == nil, presenceSummary == nil {
        if let lastError {
          return SnapshotContext(frameBase64: nil, presenceSummary: "摄像头状态：\(lastError)")
        }
        return nil
      }
      return SnapshotContext(frameBase64: frameBase64, presenceSummary: presenceSummary)
    }
  }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension WebcamObserver: AVCaptureVideoDataOutputSampleBufferDelegate {
  func captureOutput(
    _ output: AVCaptureOutput,
    didOutput sampleBuffer: CMSampleBuffer,
    from connection: AVCaptureConnection
  ) {
    handleVideoFrame(sampleBuffer)
  }
}
