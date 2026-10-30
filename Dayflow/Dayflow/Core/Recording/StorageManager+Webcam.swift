//
//  StorageManager+Webcam.swift
//  Dayflow
//
//  Persistence for the experimental webcam observation module: downscaled
//  frames for playback, and intrusion events (peeking / stranger-at-keyboard)
//  with optional audio recordings. All local-only.
//

import Foundation
import GRDB
import ImageIO

struct WebcamFrameRow {
  let id: Int64
  let capturedAt: Int
  let filePath: String
  let faceCount: Int
  let state: String?
}

struct WebcamEventRow {
  let id: Int64
  let type: String
  let startTs: Int
  let endTs: Int?
  let audioPath: String?
  let faceCountMax: Int
}

extension StorageManager {
  private static var webcamSchemaInstalled = false

  /// Idempotent: cheap after the first call in this process.
  func ensureWebcamSchema() {
    guard !Self.webcamSchemaInstalled else { return }
    try? timedWrite("ensureWebcamSchema") { db in
      try db.execute(
        sql: """
              CREATE TABLE IF NOT EXISTS webcam_frames (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  captured_at INTEGER NOT NULL,
                  file_path TEXT NOT NULL,
                  face_count INTEGER NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_webcam_frames_time ON webcam_frames(captured_at);
              CREATE TABLE IF NOT EXISTS webcam_events (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  type TEXT NOT NULL,
                  start_ts INTEGER NOT NULL,
                  end_ts INTEGER,
                  audio_path TEXT,
                  face_count_max INTEGER NOT NULL DEFAULT 0,
                  created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
              );
              CREATE INDEX IF NOT EXISTS idx_webcam_events_time ON webcam_events(start_ts);
        """)
      try? db.execute(sql: "ALTER TABLE webcam_frames ADD COLUMN state TEXT")
    }
    Self.webcamSchemaInstalled = true
  }

  // MARK: - Paths

  func webcamFramesDirectory(for date: Date = Date()) -> URL {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd"
    df.locale = Locale(identifier: "en_US_POSIX")
    let dir = root.appendingPathComponent("webcam").appendingPathComponent(df.string(from: date))
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  func webcamAudioDirectory() -> URL {
    let dir = root.appendingPathComponent("webcam-audio")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - Frames

  /// Writes the JPEG beside the recordings and records the row. Returns row id.
  func saveWebcamFrame(jpegData: Data, capturedAt: Date, faceCount: Int) -> Int64? {
    ensureWebcamSchema()
    let df = DateFormatter()
    df.dateFormat = "yyyyMMdd_HHmmssSSS"
    df.locale = Locale(identifier: "en_US_POSIX")
    let url = webcamFramesDirectory(for: capturedAt)
      .appendingPathComponent("\(df.string(from: capturedAt)).jpg")
    do {
      try jpegData.write(to: url, options: .atomic)
    } catch {
      return nil
    }

    var frameId: Int64?
    try? timedWrite("saveWebcamFrame") { db in
      try db.execute(
        sql: "INSERT INTO webcam_frames(captured_at, file_path, face_count) VALUES (?, ?, ?)",
        arguments: [Int(capturedAt.timeIntervalSince1970), url.path, faceCount])
      frameId = db.lastInsertedRowID
    }
    return frameId
  }

  /// Nearest stored frame within `withinSeconds`; nil when nothing is close.
  func nearestWebcamFrame(at timestamp: Int, withinSeconds: Int = 90) -> WebcamFrameRow? {
    ensureWebcamSchema()
    return try? timedRead("nearestWebcamFrame") { db in
      let row = try Row.fetchOne(
        db,
        sql: """
              SELECT id, captured_at, file_path, face_count, state FROM webcam_frames
              WHERE captured_at BETWEEN ? AND ?
              ORDER BY ABS(captured_at - ?) LIMIT 1
        """,
        arguments: [timestamp - withinSeconds, timestamp + withinSeconds, timestamp])
      guard let row else { return nil }
      return WebcamFrameRow(
        id: row["id"] as Int64? ?? 0,
        capturedAt: row["captured_at"] as Int? ?? 0,
        filePath: row["file_path"] as String? ?? "",
        faceCount: row["face_count"] as Int? ?? 0,
        state: row["state"] as String?)
    }
  }

  /// Decoded image for the playback picture-in-picture.
  func loadWebcamImage(at timestamp: Int) -> CGImage? {
    guard let frame = nearestWebcamFrame(at: timestamp) else { return nil }
    let url = URL(fileURLWithPath: frame.filePath) as CFURL
    guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  // MARK: - Events

  func insertWebcamEvent(type: String, startTs: Date, faceCountMax: Int) -> Int64? {
    ensureWebcamSchema()
    var eventId: Int64?
    try? timedWrite("insertWebcamEvent") { db in
      try db.execute(
        sql: "INSERT INTO webcam_events(type, start_ts, face_count_max) VALUES (?, ?, ?)",
        arguments: [type, Int(startTs.timeIntervalSince1970), faceCountMax])
      eventId = db.lastInsertedRowID
    }
    return eventId
  }

  func finishWebcamEvent(id: Int64, endTs: Date, audioPath: String?) {
    ensureWebcamSchema()
    try? timedWrite("finishWebcamEvent") { db in
      try db.execute(
        sql: "UPDATE webcam_events SET end_ts = ?, audio_path = ? WHERE id = ?",
        arguments: [Int(endTs.timeIntervalSince1970), audioPath, id])
    }
  }

  func recentWebcamEvents(since timestamp: Int) -> [WebcamEventRow] {
    ensureWebcamSchema()
    return (try? timedRead("recentWebcamEvents") { db in
      let rows = try Row.fetchAll(
        db,
        sql: """
              SELECT id, type, start_ts, end_ts, audio_path, face_count_max FROM webcam_events
              WHERE start_ts >= ? ORDER BY start_ts DESC LIMIT 20
        """,
        arguments: [timestamp])
      return rows.map { row in
        WebcamEventRow(
          id: row["id"] as Int64? ?? 0,
          type: row["type"] as String? ?? "",
          startTs: row["start_ts"] as Int? ?? 0,
          endTs: row["end_ts"] as Int?,
          audioPath: row["audio_path"] as String?,
          faceCountMax: row["face_count_max"] as Int? ?? 0)
      }
    }) ?? []
  }

  // MARK: - Retention

  /// 仅清理过期录音文件（画面帧持续保存，直到在设置里手工清除）。
  @discardableResult
  func purgeWebcamAudio(audioDays: Int) -> Int {
    ensureWebcamSchema()
    let audioCutoff = Int(
      Date().addingTimeInterval(-TimeInterval(audioDays * 24 * 3600)).timeIntervalSince1970)
    let audioPaths: [String] = (try? timedRead("purgeWebcamAudioPaths") { db in
      try String.fetchAll(
        db,
        sql: """
              SELECT audio_path FROM webcam_events
              WHERE end_ts IS NOT NULL AND end_ts < ? AND audio_path IS NOT NULL
        """,
        arguments: [audioCutoff])
    }) ?? []
    for path in audioPaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    return audioPaths.count
  }

  /// 手工清除：删除全部已保存画面帧（安全事件记录保留）。
  @discardableResult
  func purgeAllWebcamFrames() -> Int {
    ensureWebcamSchema()
    let framePaths: [String] = (try? timedRead("allWebcamFramePaths") { db in
      try String.fetchAll(db, sql: "SELECT file_path FROM webcam_frames")
    }) ?? []
    for path in framePaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    try? timedWrite("purgeAllWebcamFrames") { db in
      try db.execute(sql: "DELETE FROM webcam_frames")
    }
    return framePaths.count
  }

  /// 摄像头相关目录磁盘占用（字节）。
  func webcamDiskUsageBytes() -> Int64 {
    let dirs = [root.appendingPathComponent("webcam"), webcamAudioDirectory()]
    var total: Int64 = 0
    let fm = FileManager.default
    for dir in dirs {
      guard
        let enumerator = fm.enumerator(
          at: dir, includingPropertiesForKeys: [.fileSizeKey])
      else { continue }
      for case let url as URL in enumerator {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
          total += Int64(size)
        }
      }
    }
    return total
  }

  // MARK: - 状态回写与每日统计

  /// 转录完成后把「摄像头：…」状态行回写到时间上最近的一帧。
  func updateWebcamFrameState(nearestTo timestamp: Int, stateLine: String) {
    ensureWebcamSchema()
    try? timedWrite("updateWebcamFrameState") { db in
      try db.execute(
        sql: """
              UPDATE webcam_frames SET state = ? WHERE id = (
                  SELECT id FROM webcam_frames
                  WHERE captured_at BETWEEN ? AND ?
                  ORDER BY ABS(captured_at - ?) LIMIT 1
              )
        """,
        arguments: [stateLine, timestamp - 120, timestamp + 120, timestamp])
    }
  }

  struct WebcamDailyStats {
    var frameCount = 0
    var presentFrames = 0
    var sittingMinutes = 0
    var restMinutes = 0
    var drinkingEpisodes = 0
    var awayFrames = 0
    var moodCounts: [(String, Int)] = []
    var busyByHour: [(Int, Int)] = []
  }

  /// 每日个人状态统计。帧采样间隔 60 秒：在场帧数≈在场分钟数；
  /// 活动分类取自转录回写的 state 行；喝水次数按连续段计一次。
  func webcamDailyStats(forDay dayStart: Date) -> WebcamDailyStats {
    ensureWebcamSchema()
    var stats = WebcamDailyStats()
    let start = Int(dayStart.timeIntervalSince1970)
    let end = start + 24 * 3600
    let rows = (try? timedRead("webcamDailyStats") { db in
      let r = try Row.fetchAll(
        db,
        sql: """
              SELECT captured_at, face_count, state FROM webcam_frames
              WHERE captured_at >= ? AND captured_at < ? ORDER BY captured_at
        """,
        arguments: [start, end])
      return r.map { row in
        (
          ts: row["captured_at"] as Int? ?? 0,
          faces: row["face_count"] as Int? ?? 0,
          state: row["state"] as String? ?? ""
        )
      }
    }) ?? []

    stats.frameCount = rows.count
    var prevDrinking = false
    var moodTally: [String: Int] = [:]
    var hourTally: [Int: Int] = [:]

    for row in rows {
      if row.faces >= 1 {
        stats.presentFrames += 1
        let hour = (row.ts % 86400) / 3600
        hourTally[hour, default: 0] += 1
      } else {
        stats.awayFrames += 1
      }
      let state = row.state
      let drinking = state.contains("喝水")
      if drinking { stats.drinkingEpisodes += (prevDrinking ? 0 : 1) }
      prevDrinking = drinking
      if state.contains("活动=工作") || state.contains("活动=交谈") { stats.sittingMinutes += 1 }
      if state.contains("活动=休息") { stats.restMinutes += 1 }
      for mood in ["专注", "正常", "疲惫", "紧张"] where state.contains("精神状态=" + mood) {
        moodTally[mood, default: 0] += 1
      }
    }

    stats.moodCounts = moodTally.sorted { $0.value > $1.value }
    stats.busyByHour = hourTally.sorted { $0.key < $1.key }
    return stats
  }
}
