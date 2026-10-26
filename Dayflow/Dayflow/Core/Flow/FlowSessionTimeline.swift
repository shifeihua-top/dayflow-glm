//
//  FlowSessionTimeline.swift
//  Dayflow
//
//  The session's activity timeline for the summary screen, written by the
//  distraction agent's model the way Dayflow's timeline cards are: not one
//  row per screenshot, but a grouping the model revises as it goes. About
//  once a minute a tick asks for the full timeline so far; the model folds
//  in the latest checks and condenses earlier stretches with hindsight
//  (merging same-work blocks, keeping short detours and breaks as their own
//  splits). Native validates the result, pins the exact break spans it
//  knows about, attaches app icons from its per-tick observations, and
//  writes everything to a JSON file. When the session ends the summary takes
//  whatever the last update produced — no extra model turn.
//

import AppKit
import Foundation

@MainActor
final class FlowSessionTimeline: ObservableObject {
  static let shared = FlowSessionTimeline()

  enum Kind: String, Codable {
    case focused
    case distracted
    case `break`
  }

  /// One row of the summary log.
  struct Entry: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var kind: Kind
    var startedAt: Date
    var endedAt: Date
    /// Frontmost app's icon as a data: URL (32px PNG), when we had one.
    var iconURL: String?
    /// Titles of the user's listed tasks the model saw finished in this
    /// stretch, for the summary's "task done" callout.
    var completedTasks: [String]?
    /// Which of the user's Dayflow categories the model filed this stretch
    /// under, spelled as the category is. Nil on breaks and on a name the
    /// user doesn't have.
    var category: String?
    /// The website or app the model says the stretch was mostly about
    /// ("youtube.com", "Xcode"), as timeline cards have. Picks the icon.
    var site: String?
  }

  /// What native saw on one tick: the model's verdict plus the frontmost app.
  struct Observation: Codable, Equatable {
    var at: Date
    var offTask: Bool
    var bundleId: String?
    var appName: String?
    var reason: String?
  }

  /// A timeline item as the model writes it (times as 24h "HH:mm").
  struct ModelItem: Decodable {
    let start: String?
    let end: String?
    let title: String?
    let kind: String?
    let completed: [String]?
    let category: String?
    let site: String?
  }

  private struct File: Codable {
    var sessionStartedAt: Date
    var updatedAt: Date
    var entries: [Entry]
    var observations: [Observation]
    var breaks: [Span]
  }

  struct Span: Codable, Equatable {
    var start: Date
    var end: Date?
  }

  @Published private(set) var entries: [Entry] = []
  @Published private(set) var observations: [Observation] = []
  private(set) var breaks: [Span] = []
  private(set) var sessionStartedAt = Date()
  private(set) var updatedAt: Date?
  /// When the model last delivered a timeline (drives the once-a-minute ask).
  private(set) var lastModelUpdateAt: Date?

  /// Where the timeline lives on disk (Application Support/Dayflow/).
  let fileURL: URL = {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("Dayflow", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("flow-session-timeline.json")
  }()

  private init() {}

  // MARK: - Session lifecycle

  /// Called when the agent starts watching a session. Keeps what's on disk
  /// if it belongs to this same session (a relaunch or re-brief); otherwise
  /// starts empty.
  func begin(sessionStartedAt started: Date) {
    if let file = load(), abs(file.sessionStartedAt.timeIntervalSince(started)) < 5 {
      sessionStartedAt = file.sessionStartedAt
      entries = file.entries
      observations = file.observations
      breaks = file.breaks
      updatedAt = file.updatedAt
      lastModelUpdateAt = file.entries.isEmpty ? nil : file.updatedAt
      return
    }
    sessionStartedAt = started
    entries = []
    observations = []
    breaks = []
    updatedAt = nil
    lastModelUpdateAt = nil
    save()
  }

  /// Every tick's verdict lands here, timeline update or not.
  func observe(offTask: Bool, front: FrontApp, reason: String?, at now: Date = Date()) {
    observations.append(
      Observation(
        at: now, offTask: offTask, bundleId: front.bundleId, appName: front.name,
        reason: reason))
    if observations.count > 2000 { observations.removeFirst(observations.count - 2000) }
    save()
  }

  func beginBreak(at now: Date = Date()) {
    if let last = breaks.last, last.end == nil { return }
    breaks.append(Span(start: now, end: nil))
    save()
  }

  func endBreak(at now: Date = Date()) {
    guard var last = breaks.last, last.end == nil else { return }
    last.end = now
    breaks[breaks.count - 1] = last
    save()
  }

  /// Whether the next tick should ask the model for a timeline update.
  func wantsUpdate(every interval: TimeInterval, at now: Date = Date()) -> Bool {
    guard let last = lastModelUpdateAt else {
      // First one once there's a minute of session to describe.
      return now.timeIntervalSince(sessionStartedAt) >= min(interval, 60)
    }
    return now.timeIntervalSince(last) >= interval
  }

  /// The model's revised timeline. Times come as "HH:mm" on the session's
  /// day; entries are sorted, clamped to the session, snapped so they're
  /// contiguous, cut around the exact break spans, and given icons.
  func apply(modelItems: [ModelItem], at now: Date = Date()) {
    var parsed: [Entry] = []
    let categories = Self.categoryNames()
    for item in modelItems {
      guard let title = item.title.map(Self.tidy), !title.isEmpty,
        let start = date(fromClock: item.start, near: now),
        let end = date(fromClock: item.end, near: now)
      else { continue }
      let word = (item.kind ?? "").lowercased()
      let kind = Kind(rawValue: word) ?? (word == "off_task" ? .distracted : .focused)
      parsed.append(
        Entry(
          id: UUID().uuidString, title: title, kind: kind,
          startedAt: max(sessionStartedAt, start), endedAt: min(now, max(start, end)),
          iconURL: nil,
          completedTasks: kind == .focused ? Self.tidyCompleted(item.completed) : nil,
          category: kind == .break
            ? nil
            : Self.matchCategory(item.category, distracted: kind == .distracted, in: categories),
          site: kind == .break ? nil : Self.tidySite(item.site)))
    }
    parsed.sort { $0.startedAt < $1.startedAt }
    // Contiguous: each entry starts where the previous ended; drop empties.
    var cursor = sessionStartedAt
    var contiguous: [Entry] = []
    for var entry in parsed {
      entry.startedAt = max(cursor, min(entry.startedAt, now))
      entry.endedAt = max(entry.startedAt, entry.endedAt)
      guard entry.endedAt > entry.startedAt else { continue }
      contiguous.append(entry)
      cursor = entry.endedAt
    }
    guard !contiguous.isEmpty else { return }
    // Blips don't split a stretch: an entry under two minutes with the same
    // kind on both sides folds into them.
    var index = 1
    while index < contiguous.count - 1 {
      let blip = contiguous[index]
      let before = contiguous[index - 1]
      let after = contiguous[index + 1]
      let short = blip.endedAt.timeIntervalSince(blip.startedAt) < 120
      guard short, blip.kind != .break, before.kind == after.kind, before.kind != blip.kind,
        blip.completedTasks == nil
      else {
        index += 1
        continue
      }
      var joined = before
      if after.endedAt.timeIntervalSince(after.startedAt)
        > before.endedAt.timeIntervalSince(before.startedAt)
      {
        joined.title = after.title
        joined.category = after.category ?? before.category
        joined.site = after.site ?? before.site
      }
      joined.endedAt = after.endedAt
      joined.completedTasks = (before.completedTasks ?? []) + (after.completedTasks ?? [])
      if joined.completedTasks?.isEmpty == true { joined.completedTasks = nil }
      contiguous.replaceSubrange((index - 1)...(index + 1), with: [joined])
    }
    // One drift is one entry, however many sites it passed through. The
    // longer piece's title wins.
    contiguous = contiguous.reduce(into: [Entry]()) { merged, entry in
      guard let last = merged.last, last.kind == .distracted, entry.kind == .distracted else {
        merged.append(entry)
        return
      }
      var joined = last
      if entry.endedAt.timeIntervalSince(entry.startedAt)
        > last.endedAt.timeIntervalSince(last.startedAt)
      {
        joined.title = entry.title
        joined.category = entry.category ?? last.category
        joined.site = entry.site ?? last.site
      }
      joined.endedAt = entry.endedAt
      merged[merged.count - 1] = joined
    }
    var result = overlayBreaks(on: contiguous, until: now)
    for index in result.indices where result[index].kind != .break {
      result[index].iconURL = icon(for: result[index])
    }
    // A break can cut an entry in two; a finished task belongs to the later
    // piece only, and is listed once across the session.
    var seen: Set<String> = []
    for index in result.indices.reversed() {
      guard let done = result[index].completedTasks else { continue }
      let fresh = done.filter { seen.insert($0.lowercased()).inserted }
      result[index].completedTasks = fresh.isEmpty ? nil : fresh
    }
    entries = result
    lastModelUpdateAt = now
    save()
    fetchSiteIcons()
  }

  /// The user's categories an entry can be filed under, in their order. Idle
  /// and system categories are never work or distraction, so they're left out.
  static func categoryNames() -> [String] {
    CategoryStore.shared.categories
      .filter { !$0.isIdle && !$0.isSystem }
      .sorted { $0.order < $1.order }
      .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  /// The model's category, as the user spells it. A name they don't have is
  /// dropped, except that a distraction falls back to their distraction
  /// category when there is one.
  static func matchCategory(_ raw: String?, distracted: Bool, in names: [String]) -> String? {
    let wanted = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !wanted.isEmpty, let match = names.first(where: { $0.lowercased() == wanted }) {
      return match
    }
    guard distracted else { return nil }
    return names.first { $0.lowercased().contains("distract") }
  }

  private static func tidyCompleted(_ titles: [String]?) -> [String]? {
    let cleaned = (titles ?? []).map(tidy).filter { !$0.isEmpty }
    return cleaned.isEmpty ? nil : Array(cleaned.prefix(5))
  }

  /// The session is over: the last entry runs to the end so the final bar
  /// doesn't stop a tick short. No model turn — we show what we have.
  func finish(at now: Date = Date()) {
    endBreak(at: now)
    guard var last = entries.last, last.endedAt < now,
      now.timeIntervalSince(last.endedAt) < 15 * 60
    else { return }
    last.endedAt = now
    entries[entries.count - 1] = last
    save()
  }

  func clear() {
    entries = []
    observations = []
    breaks = []
    updatedAt = nil
    lastModelUpdateAt = nil
    try? FileManager.default.removeItem(at: fileURL)
  }

  // MARK: - Prompt material

  /// The current timeline as the model last wrote it, for revision.
  func promptTimelineJSON() -> String {
    guard !entries.isEmpty else { return "[]" }
    // Built incrementally: one giant interpolation expression here can push
    // the type checker past its time limit on newer toolchains.
    let rows = entries.map { entry -> String in
      var row =
        "{\"start\":\"\(Self.clock(entry.startedAt))\",\"end\":\"\(Self.clock(entry.endedAt))\","
      row += "\"kind\":\"\(entry.kind.rawValue)\",\"title\":\(Self.jsonString(entry.title))"
      if let category = entry.category {
        row += ",\"category\":\(Self.jsonString(category))"
      }
      if let site = entry.site {
        row += ",\"site\":\(Self.jsonString(site))"
      }
      if let tasks = entry.completedTasks {
        row += ",\"completed\":[" + tasks.map(Self.jsonString).joined(separator: ",") + "]"
      }
      row += "}"
      return row
    }
    return "[\n" + rows.joined(separator: ",\n") + "\n]"
  }

  /// Native's per-tick log since the last timeline update, one line each.
  func promptObservations(since: Date?) -> String {
    let recent = observations.filter { since == nil || $0.at > since! }
    guard !recent.isEmpty else { return "(no checks since the last update)" }
    return recent.map { observation in
      var line = "\(Self.clock(observation.at)) \(observation.offTask ? "off_task" : "on_task")"
      if let app = observation.appName { line += " · \(app)" }
      if let reason = observation.reason, !reason.isEmpty { line += " · \(reason)" }
      return line
    }.joined(separator: "\n")
  }

  func promptBreaks() -> String {
    guard !breaks.isEmpty else { return "(none)" }
    return breaks.map { span in
      "\(Self.clock(span.start))–\(span.end.map(Self.clock) ?? "ongoing")"
    }.joined(separator: ", ")
  }

  // MARK: - Bridge

  /// Entries in the shape the web summary's `FlowActivity` expects.
  var bridgePayload: [[String: Any]] {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return entries.map { entry in
      var payload: [String: Any] = [
        "id": entry.id,
        "title": entry.title,
        "kind": entry.kind.rawValue,
        "started_at": formatter.string(from: entry.startedAt),
        "ended_at": formatter.string(from: entry.endedAt),
      ]
      if let icon = entry.iconURL { payload["icon_url"] = icon }
      if let done = entry.completedTasks { payload["completed_tasks"] = done }
      if let category = entry.category { payload["category"] = category }
      return payload
    }
  }

  // MARK: - App icons

  struct FrontApp {
    var bundleId: String?
    var name: String?
    var iconURL: String?
    static let none = FrontApp()
  }

  /// The frontmost app right now, with its icon as a small PNG data URL.
  nonisolated static func frontmostApp() -> FrontApp {
    guard let app = NSWorkspace.shared.frontmostApplication else { return .none }
    // Dayflow's own overlay/window in front tells us nothing about the work.
    if app.bundleIdentifier == Bundle.main.bundleIdentifier { return .none }
    return FrontApp(
      bundleId: app.bundleIdentifier, name: app.localizedName, iconURL: iconDataURL(for: app))
  }

  private nonisolated(unsafe) static var iconCache: [String: String] = [:]
  private nonisolated static let iconCacheLock = NSLock()

  private nonisolated static func iconDataURL(for app: NSRunningApplication) -> String? {
    let key = app.bundleIdentifier ?? app.localizedName ?? ""
    iconCacheLock.lock()
    if let cached = iconCache[key] {
      iconCacheLock.unlock()
      return cached
    }
    iconCacheLock.unlock()
    guard let icon = app.icon else { return nil }
    let size = NSSize(width: 32, height: 32)
    let small = NSImage(size: size)
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    icon.draw(
      in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    let url = "data:image/png;base64," + png.base64EncodedString()
    iconCacheLock.lock()
    iconCache[key] = url
    iconCacheLock.unlock()
    return url
  }

  // MARK: - Site icons

  /// Favicons already turned into data URLs, by site as the model wrote it.
  private var siteIcons: [String: String] = [:]
  private var siteFetches: Set<String> = []

  private static func tidySite(_ raw: String?) -> String? {
    let site = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return site.isEmpty || site.count > 80 ? nil : site
  }

  /// A website is a name with a dot in it; anything else is an app's name.
  private static func isWebsite(_ site: String) -> Bool {
    site.contains(".") && !site.contains(" ")
  }

  /// The icon for an entry, the way a timeline card picks its own: the site
  /// or app the model named, when we have its icon. In a browser the app is the same for work and for YouTube, so
  /// the site says far more.
  private func icon(for entry: Entry) -> String? {
    if let site = entry.site {
      if let known = siteIcons[site.lowercased()] { return known }
      if let image = FaviconService.shared.cachedOrRawFavicon(
        primaryRaw: site, secondaryRaw: nil,
        primaryHost: Self.isWebsite(site) ? FaviconService.normalizedHost(from: site) : nil,
        secondaryHost: nil), let url = Self.dataURL(for: image)
      {
        siteIcons[site.lowercased()] = url
        return url
      }
      if !Self.isWebsite(site), let named = iconForApp(named: site) { return named }
    }
    // Nothing recognisable: no icon, and the page draws a dot in the
    // category's colour instead of whichever app happened to be in front.
    return nil
  }

  /// Fetches the favicons the current entries still lack, then fills them in.
  private func fetchSiteIcons() {
    let wanted = Set(
      entries.compactMap { $0.site?.lowercased() }
        .filter { Self.isWebsite($0) && siteIcons[$0] == nil && !siteFetches.contains($0) })
    for site in wanted {
      siteFetches.insert(site)
      Task { [weak self] in
        let image = await FaviconService.shared.fetchFavicon(
          primaryRaw: site, secondaryRaw: nil,
          primaryHost: FaviconService.normalizedHost(from: site), secondaryHost: nil)
        guard let self, let image, let url = Self.dataURL(for: image) else { return }
        self.siteIcons[site] = url
        var changed = false
        for index in self.entries.indices where self.entries[index].site?.lowercased() == site {
          self.entries[index].iconURL = url
          changed = true
        }
        if changed { self.save() }
      }
    }
  }

  /// The icon of a running app the model named ("Xcode"), if it was in front.
  private func iconForApp(named name: String) -> String? {
    let wanted = name.lowercased()
    guard
      let bundleId = observations.last(where: { $0.appName?.lowercased() == wanted })?.bundleId
    else { return nil }
    Self.iconCacheLock.lock()
    let cached = Self.iconCache[bundleId]
    Self.iconCacheLock.unlock()
    return cached
  }

  private nonisolated static func dataURL(for image: NSImage) -> String? {
    let size = NSSize(width: 32, height: 32)
    let small = NSImage(size: size)
    small.lockFocus()
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
    small.unlockFocus()
    guard let tiff = small.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
    else { return nil }
    return "data:image/png;base64," + png.base64EncodedString()
  }

  // MARK: - Breaks

  /// Native knows exactly when breaks happened; cut them into the model's
  /// entries so break bars are precise whatever the model wrote.
  private func overlayBreaks(on entries: [Entry], until now: Date) -> [Entry] {
    var result = entries.filter { $0.kind != .break }
    for span in breaks {
      let breakStart = span.start
      let breakEnd = min(now, span.end ?? now)
      guard breakEnd > breakStart else { continue }
      var next: [Entry] = []
      for entry in result {
        if entry.endedAt <= breakStart || entry.startedAt >= breakEnd {
          next.append(entry)
          continue
        }
        if entry.startedAt < breakStart {
          var head = entry
          head.endedAt = breakStart
          next.append(head)
        }
        if entry.endedAt > breakEnd {
          var tail = entry
          tail.id = UUID().uuidString
          tail.startedAt = breakEnd
          next.append(tail)
        }
      }
      next.append(
        Entry(
          id: UUID().uuidString, title: "Break", kind: .break, startedAt: breakStart,
          endedAt: breakEnd, iconURL: nil))
      result = next.sorted { $0.startedAt < $1.startedAt }
    }
    return result
  }

  // MARK: - Helpers

  private static let clockFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm"
    return formatter
  }()

  static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }

  /// "HH:mm" (or "h:mm a") on the session's day, choosing the day so the
  /// result lands nearest the session (handles a session crossing midnight).
  private func date(fromClock text: String?, near now: Date) -> Date? {
    guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    var hour = 0
    var minute = 0
    let lower = text.lowercased()
    let digits = lower.replacingOccurrences(of: "am", with: "").replacingOccurrences(
      of: "pm", with: ""
    ).trimmingCharacters(in: .whitespaces)
    let parts = digits.split(separator: ":")
    guard parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1].prefix(2)) else {
      return nil
    }
    hour = h
    minute = m
    if lower.contains("pm"), hour < 12 { hour += 12 }
    if lower.contains("am"), hour == 12 { hour = 0 }
    guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
    let calendar = Calendar.current
    let candidates = [-1, 0, 1].compactMap { offset -> Date? in
      guard let day = calendar.date(byAdding: .day, value: offset, to: sessionStartedAt) else {
        return nil
      }
      return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
    }
    let middle = sessionStartedAt.addingTimeInterval(now.timeIntervalSince(sessionStartedAt) / 2)
    return candidates.min { abs($0.timeIntervalSince(middle)) < abs($1.timeIntervalSince(middle)) }
  }

  private static func tidy(_ title: String) -> String {
    var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
    while text.hasSuffix(".") { text.removeLast() }
    if text.count > 60 { text = String(text.prefix(57)) + "…" }
    guard let first = text.first else { return "" }
    return first.uppercased() + text.dropFirst()
  }

  private static func jsonString(_ value: String) -> String {
    let data = try? JSONSerialization.data(withJSONObject: [value])
    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
    return String(text.dropFirst().dropLast())
  }

  private func save() {
    updatedAt = Date()
    let file = File(
      sessionStartedAt: sessionStartedAt, updatedAt: updatedAt!, entries: entries,
      observations: observations, breaks: breaks)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(file) else { return }
    try? data.write(to: fileURL, options: .atomic)
  }

  private func load() -> File? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(File.self, from: data)
  }
}
