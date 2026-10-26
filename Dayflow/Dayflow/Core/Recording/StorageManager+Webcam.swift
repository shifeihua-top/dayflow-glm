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
  private static let webcamSchemaKey = "webcamSchemaInstalled"

  /// Idempotent: cheap after the first call in this process.
  func ensureWebcamSchema() {
    guard objc_getAssociatedObject(self, &Self.webcamSchemaKey) == nil else { return }
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
    }
    objc_setAssociatedObject(self, &Self.webcamSchemaKey, NSObject(), .OBJC_ASSOCIATION_RETAIN)
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
              SELECT id, captured_at, file_path, face_count FROM webcam_frames
              WHERE captured_at BETWEEN ? AND ?
              ORDER BY ABS(captured_at - ?) LIMIT 1
        """,
        arguments: [timestamp - withinSeconds, timestamp + withinSeconds, timestamp])
      guard let row else { return nil }
      return WebcamFrameRow(
        id: row["id"] as Int64? ?? 0,
        capturedAt: row["captured_at"] as Int? ?? 0,
        filePath: row["file_path"] as String? ?? "",
        faceCount: row["face_count"] as Int? ?? 0)
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

  /// Deletes webcam frame files/rows and finished audio files older than the cap.
  @discardableResult
  func purgeWebcamData(olderThanDays days: Int) -> Int {
    ensureWebcamSchema()
    let cutoff = Int(Date().addingTimeInterval(-TimeInterval(days * 24 * 3600)).timeIntervalSince1970)
    var removed = 0

    let framePaths: [String] = (try? timedRead("purgeWebcamFramePaths") { db in
      String.fetchAll(
        db, sql: "SELECT file_path FROM webcam_frames WHERE captured_at < ?", arguments: [cutoff])
    }) ?? []
    for path in framePaths {
      try? FileManager.default.removeItem(atPath: path)
      removed += 1
    }
    try? timedWrite("purgeWebcamFrames") { db in
      try db.execute(sql: "DELETE FROM webcam_frames WHERE captured_at < ?", arguments: [cutoff])
    }

    let audioPaths: [String] = (try? timedRead("purgeWebcamAudioPaths") { db in
      String.fetchAll(
        db,
        sql: """
              SELECT audio_path FROM webcam_events
              WHERE end_ts IS NOT NULL AND end_ts < ? AND audio_path IS NOT NULL
        """,
        arguments: [cutoff])
    }) ?? []
    for path in audioPaths {
      try? FileManager.default.removeItem(atPath: path)
    }
    try? timedWrite("purgeWebcamEvents") { db in
      try db.execute(
        sql: "DELETE FROM webcam_events WHERE end_ts IS NOT NULL AND end_ts < ?", arguments: [cutoff])
    }
    return removed
  }
}
