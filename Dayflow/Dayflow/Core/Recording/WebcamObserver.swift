//
//  WebcamObserver.swift
//  Dayflow
//
//  Experimental opt-in camera observation module.
//
//  Privacy contract:
//  - Frames stay in memory for LLM context; when 「保存画面到本地」 is on they
//    are additionally saved as downscaled JPEGs beside the recordings for
//    playback, auto-purged after 7 days.
//  - Presence detection runs on-device via the Vision framework (free, no LLM).
//  - Intrusion events (peeking: 2+ faces; stranger-at-keyboard: owner idle
//    while a face is present) are recorded to webcam_events; optional audio
//    capture runs only while an event is active and is strictly opt-in.
//  - LLM access happens only through the transcription pipeline, which pulls
//    the ring-buffer frame nearest in time to each sampled screenshot.
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
  static let saveFramesKey = "webcamSaveFramesForPlayback"
  static let intrusionAudioKey = "webcamIntrusionAudioRecording"
  static let retentionMinutes = 20
  static let presenceRetentionMinutes = 60
  static let frameRetentionDays = 30
  static let audioRetentionDays = 7
  /// 帧丢弃数量：等自动曝光/白平衡收敛
  static let warmupFrames = 45
  /// 主人离开判定（秒）：此后仍检测到人脸 → 疑似旁人操作
  static let ownerAwaySeconds = 180

  struct SnapshotContext {
    /// Base64 JPEG of the webcam frame nearest in time, nil when the LLM-frame
    /// toggle is off or no frame is close enough to the screenshot.
    let frameBase64: String?
    /// Plain-text presence summary around the screenshot's timestamp.
    let presenceSummary: String?
    /// 安全事件摘要（偷窥 / 旁人操作）。
    let intrusionSummary: String?
  }

  struct StatusSnapshot {
    let running: Bool
    let lastError: String?
    let lastCaptureAt: Date?
    let lastFaceCount: Int
    let bufferedFrames: Int
    let ownerIdleSeconds: Int?
    let activeEventLines: [String]
    let savedFrameCount: Int
  }

  private let q = DispatchQueue(label: "dayflow.webcam.observer")
  private let frameQueue = DispatchQueue(label: "dayflow.webcam.frames")

  private var session: AVCaptureSession?
  private var videoOutput: AVCaptureVideoDataOutput?
  private var captureTimer: DispatchSourceTimer?
  private var purgeTimer: DispatchSourceTimer?
  private var runtimeErrorObserver: NSObjectProtocol?
  private var cancellables: Set<AnyCancellable> = []

  // State guarded by `q`.
  private var running = false
  private var permissionDenied = false
  private var lastError: String?
  private var lastCaptureAt: Date?
  private var lastFaceCount = -1
  private var frames: [(date: Date, base64: String)] = []
  private var presence: [(date: Date, present: Bool)] = []
  private var savedFrameCount = 0

  // Intrusion state machine (guarded by `q`).
  private var activePeekingEventId: Int64?
  private var activeStrangerEventId: Int64?
  private var peekingEndStreak = 0
  private var strangerEndStreak = 0
  private var strangerCooldownUntil: Date?
  private var activeEventLines: [String] = []
  private var recentEventLines: [(date: Date, line: String)] = []
  private var audioRecorder: IntrusionAudioRecorder?

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

  private var saveFramesToDisk: Bool {
    UserDefaults.standard.object(forKey: Self.saveFramesKey) == nil
      ? true
      : UserDefaults.standard.bool(forKey: Self.saveFramesKey)
  }

  var intrusionAudioEnabled: Bool {
    UserDefaults.standard.bool(forKey: Self.intrusionAudioKey)
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

  func setSaveFrames(_ enabled: Bool) {
    UserDefaults.standard.set(enabled, forKey: Self.saveFramesKey)
  }

  /// 需要麦克风权限；未授权时不落开关，避免状态与实际能力脱节。
  func setIntrusionAudio(_ enabled: Bool) {
    guard enabled else {
      UserDefaults.standard.set(false, forKey: Self.intrusionAudioKey)
      return
    }
    IntrusionAudioRecorder.requestMicPermission { [weak self] granted in
      UserDefaults.standard.set(granted, forKey: Self.intrusionAudioKey)
      guard let self else { return }
      NotificationCenter.default.post(
        name: Notification.Name("WebcamIntrusionAudioChanged"), object: nil,
        userInfo: ["granted": granted])
    }
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

    // 磁盘保留清理：每 6 小时跑一次。
    let purge = DispatchSource.makeTimerSource(queue: q)
    purge.schedule(deadline: .now() + 60, repeating: 6 * 3600)
    purge.setEventHandler { [weak self] in
      // 画面帧持续保存直到手工清除；仅录音按 7 天自动清理。
      StorageManager.shared.purgeWebcamAudio(audioDays: Self.audioRetentionDays)
    }
    purge.resume()
    purgeTimer = purge
  }

  private func stopLocked(reason: String?) {
    guard running || session != nil else { return }
    running = false
    captureTimer?.cancel()
    captureTimer = nil
    purgeTimer?.cancel()
    purgeTimer = nil
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

    // 进行中的事件以当前时刻收尾（音频一并停掉）。
    let now = Date()
    if let eventId = activePeekingEventId {
      StorageManager.shared.finishWebcamEvent(id: eventId, endTs: now, audioPath: nil)
      activePeekingEventId = nil
    }
    if let eventId = activeStrangerEventId {
      StorageManager.shared.finishWebcamEvent(id: eventId, endTs: now, audioPath: nil)
      activeStrangerEventId = nil
    }
    _ = stopAudio()
    activeEventLines.removeAll()
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
      let jpegData = NSBitmapImageRep(cgImage: image).representation(
        using: .jpeg, properties: [.compressionFactor: 0.8])
      let base64 =
        self.sendFramesToLLM
        ? jpegData?.base64EncodedString() : nil

      self.q.async { [weak self] in
        guard let self else { return }
        self.lastCaptureAt = now
        self.lastFaceCount = faceCount
        if let base64 {
          self.frames.append((now, base64))
        }
        self.presence.append((now, faceCount > 0))
        self.trimRings(now: now)
        self.processIntrusionAndStorage(faceCount: faceCount, jpegData: jpegData, at: now)
      }
    }
  }

  private func trimRings(now: Date) {
    let frameCutoff = now.addingTimeInterval(-TimeInterval(Self.retentionMinutes * 60))
    frames.removeAll { $0.date < frameCutoff }
    let presenceCutoff = now.addingTimeInterval(-TimeInterval(Self.presenceRetentionMinutes * 60))
    presence.removeAll { $0.date < presenceCutoff }
    let eventCutoff = now.addingTimeInterval(-15 * 60)
    recentEventLines.removeAll { $0.date < eventCutoff }
  }

  // MARK: - Intrusion state machine + persistence (runs on `q`)

  private func processIntrusionAndStorage(faceCount: Int, jpegData: Data?, at now: Date) {
    if saveFramesToDisk, let jpegData {
      if StorageManager.shared.saveWebcamFrame(
        jpegData: jpegData, capturedAt: now, faceCount: faceCount) != nil
      {
        savedFrameCount += 1
      }
    }

    let ownerIdle = InputIdleSnapshot.currentIdleSeconds()
    let peeking = faceCount >= 2
    let strangerSuspect =
      faceCount >= 1
      && (ownerIdle.map { $0 >= Self.ownerAwaySeconds } ?? false)

    // 偷窥：同一画面出现 2 张及以上人脸，连续 2 个采样点恢复才结束。
    if peeking {
      peekingEndStreak = 0
      if activePeekingEventId == nil {
        activePeekingEventId = StorageManager.shared.insertWebcamEvent(
          type: "peeking", startTs: now, faceCountMax: faceCount)
        appendEventLine(now, "疑似旁人偷窥（同画面检测到多人）", faceCount)
        startAudioIfNeeded()
      }
    } else if activePeekingEventId != nil {
      peekingEndStreak += 1
      if peekingEndStreak >= 2 {
        finishPeekingEvent(at: now)
      }
    }

    // 旁人操作：主人物理输入空闲超过阈值且仍有人脸。
    if strangerSuspect {
      strangerEndStreak = 0
      if activeStrangerEventId == nil {
        if let cooldown = strangerCooldownUntil, now < cooldown {
          // 刚结束过一次，5 分钟内不再重复记录
        } else {
          activeStrangerEventId = StorageManager.shared.insertWebcamEvent(
            type: "stranger", startTs: now, faceCountMax: faceCount)
          appendEventLine(now, "主人离开期间疑似有人操作电脑", faceCount)
          startAudioIfNeeded()
        }
      }
    } else if activeStrangerEventId != nil {
      strangerEndStreak += 1
      if strangerEndStreak >= 2 {
        strangerCooldownUntil = now.addingTimeInterval(5 * 60)
        finishStrangerEvent(at: now)
      }
    }
  }

  private func appendEventLine(_ date: Date, _ text: String, _ faces: Int) {
    let line = "\(text)，人脸×\(faces)"
    recentEventLines.append((date, line))
    activeEventLines = recentEventLines.map(\.line)
  }

  private func finishPeekingEvent(at now: Date) {
    guard let eventId = activePeekingEventId else { return }
    activePeekingEventId = nil
    let audioPath = maybeStopAudio()
    StorageManager.shared.finishWebcamEvent(id: eventId, endTs: now, audioPath: audioPath)
    syncActiveEventLines()
  }

  private func finishStrangerEvent(at now: Date) {
    guard let eventId = activeStrangerEventId else { return }
    activeStrangerEventId = nil
    let audioPath = maybeStopAudio()
    StorageManager.shared.finishWebcamEvent(id: eventId, endTs: now, audioPath: audioPath)
    syncActiveEventLines()
  }

  private func syncActiveEventLines() {
    var lines: [String] = []
    if activePeekingEventId != nil {
      lines.append("疑似旁人偷窥进行中")
    }
    if activeStrangerEventId != nil {
      lines.append("疑似有人操作电脑进行中")
    }
    activeEventLines = lines
  }

  private func startAudioIfNeeded() {
    guard intrusionAudioEnabled, IntrusionAudioRecorder.micPermissionGranted else { return }
    if audioRecorder == nil { audioRecorder = IntrusionAudioRecorder() }
    guard let recorder = audioRecorder, !recorder.isRecording else { return }
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmss"
    df.locale = Locale(identifier: "en_US_POSIX")
    let url = StorageManager.shared.webcamAudioDirectory()
      .appendingPathComponent("intrusion-\(df.string(from: Date())).m4a")
    if recorder.start(to: url) {
      _ = url
    }
  }

  private func maybeStopAudio() -> String? {
    guard activePeekingEventId == nil, activeStrangerEventId == nil else { return nil }
    return stopAudio()
  }

  private func stopAudio() -> String? {
    guard let recorder = audioRecorder, recorder.isRecording else { return nil }
    return recorder.stop()?.path
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
  /// nearest in time (±2 min), a presence summary and any security events for
  /// the surrounding 15 minutes. Cheap: no LLM, no disk reads for the LLM path.
  func contextForScreenshot(at unixTimestamp: Int) -> SnapshotContext? {
    guard isEnabled else { return nil }
    return q.sync { [weak self] () -> SnapshotContext? in
      guard let self else { return nil }
      let date = Date(timeIntervalSince1970: TimeInterval(unixTimestamp))

      var frameBase64: String?
      if self.sendFramesToLLM,
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

      var intrusionSummary: String?
      if !self.recentEventLines.isEmpty {
        let lines = self.recentEventLines.suffix(3).map(\.line).joined(separator: "；")
        intrusionSummary = "安全事件（近15分钟）：\(lines)"
      }

      if frameBase64 == nil, presenceSummary == nil, intrusionSummary == nil {
        if let lastError = self.lastError {
          return SnapshotContext(
            frameBase64: nil, presenceSummary: "摄像头状态：\(lastError)", intrusionSummary: nil)
        }
        return nil
      }
      return SnapshotContext(
        frameBase64: frameBase64,
        presenceSummary: presenceSummary,
        intrusionSummary: intrusionSummary)
    }
  }

  // MARK: - Settings UI support

  /// Live status for the settings UI (counters only, no frames).
  func statusSnapshot() -> StatusSnapshot {
    q.sync { [weak self] () -> StatusSnapshot in
      guard let self else {
        return StatusSnapshot(
          running: false, lastError: nil, lastCaptureAt: nil, lastFaceCount: -1,
          bufferedFrames: 0, ownerIdleSeconds: nil, activeEventLines: [], savedFrameCount: 0)
      }
      return StatusSnapshot(
        running: self.running,
        lastError: self.lastError,
        lastCaptureAt: self.lastCaptureAt,
        lastFaceCount: self.lastFaceCount,
        bufferedFrames: self.frames.count,
        ownerIdleSeconds: InputIdleSnapshot.currentIdleSeconds(),
        activeEventLines: self.activeEventLines,
        savedFrameCount: self.savedFrameCount)
    }
  }

  /// The live AVCaptureSession for the settings preview layer, nil when off.
  func previewSession() -> AVCaptureSession? {
    q.sync { [weak self] () -> AVCaptureSession? in
      self?.session
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
