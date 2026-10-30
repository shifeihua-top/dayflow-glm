//
//  WebcamDailyReportView.swift
//  Dayflow
//
//  摄像头每日状态记录：坐了多久、喝水次数、时段忙碌、精神状态分布。
//

import SwiftUI

struct WebcamDailyReportSheet: View {
  let onClose: () -> Void
  @State private var dayOffset = 0
  @State private var stats: StorageManager.WebcamDailyStats?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Text("摄像头每日状态记录")
          .font(.custom("Figtree", size: 16))
          .fontWeight(.semibold)
        Spacer()
        Button(action: onClose) {
          Image(systemName: "xmark.circle.fill")
            .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
      }

      HStack(spacing: 12) {
        Button("‹ 前一天") { dayOffset += 1 }
          .buttonStyle(.plain)
          .pointingHandCursor()
        Text(dateLabel)
          .font(.custom("Figtree", size: 13))
          .fontWeight(.semibold)
        Button("后一天 ›") { dayOffset = max(0, dayOffset - 1) }
          .buttonStyle(.plain)
          .pointingHandCursor()
          .disabled(dayOffset == 0)
      }

      if let stats {
        if stats.frameCount == 0 {
          Text("这一天没有摄像头记录。")
            .font(.custom("Figtree", size: 13))
            .foregroundColor(.secondary)
        } else {
          VStack(alignment: .leading, spacing: 8) {
            statRow("画面采样", "\(stats.frameCount) 帧")
            statRow("在场时长", minutesText(stats.presentFrames))
            statRow("其中静坐/工作", minutesText(stats.sittingMinutes))
            statRow("休息", minutesText(stats.restMinutes))
            statRow("离开", minutesText(stats.awayFrames))
            statRow("喝水", "\(stats.drinkingEpisodes) 次")
            if !stats.moodCounts.isEmpty {
              statRow(
                "精神状态",
                stats.moodCounts.map { "\($0.0) \($0.1)" }.joined(separator: " · "))
            }
          }
          busyByHourSection(stats)
        }
      } else {
        Text("加载中…")
          .font(.custom("Figtree", size: 13))
          .foregroundColor(.secondary)
      }

      Text("画面帧持续保存，直到在设置里手工清除；状态统计随画面分析逐步补全。")
        .font(.custom("Figtree", size: 11))
        .foregroundColor(.secondary)
    }
    .padding(20)
    .frame(width: 480, alignment: .leading)
    .onAppear(perform: reload)
    .onChange(of: dayOffset) { _, _ in reload() }
  }

  private var dateLabel: String {
    let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
    let df = DateFormatter()
    df.dateFormat = "yyyy年M月d日"
    df.locale = Locale(identifier: "zh_CN")
    return df.string(from: date)
  }

  private func reload() {
    stats = nil
    let date = Calendar.current.date(byAdding: .day, value: -dayOffset, to: Date()) ?? Date()
    let dayStart = Calendar.current.startOfDay(for: date)
    DispatchQueue.global(qos: .utility).async {
      let result = StorageManager.shared.webcamDailyStats(forDay: dayStart)
      DispatchQueue.main.async { stats = result }
    }
  }

  private func minutesText(_ minutes: Int) -> String {
    guard minutes > 0 else { return "0 分钟" }
    let hours = minutes / 60
    let rest = minutes % 60
    if hours > 0, rest > 0 { return "\(hours) 小时 \(rest) 分" }
    if hours > 0 { return "\(hours) 小时" }
    return "\(rest) 分钟"
  }

  private func statRow(_ label: String, _ value: String) -> some View {
    HStack {
      Text(label)
        .font(.custom("Figtree", size: 13))
        .foregroundColor(.secondary)
      Spacer()
      Text(value)
        .font(.custom("Figtree", size: 13))
        .fontWeight(.semibold)
    }
  }

  @ViewBuilder
  private func busyByHourSection(_ stats: StorageManager.WebcamDailyStats) -> some View {
    let bars = stats.busyByHour
    if !bars.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        Text("各时段在场情况（忙碌程度）")
          .font(.custom("Figtree", size: 13))
          .foregroundColor(.secondary)
        HStack(alignment: .bottom, spacing: 3) {
          let maxValue = max(bars.map { $0.1 }.max() ?? 1, 1)
          ForEach(bars, id: \.0) { hour, count in
            VStack(spacing: 2) {
              RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.75))
                .frame(height: max(4, CGFloat(count) / CGFloat(maxValue) * 56))
              if hour % 4 == 0 {
                Text("\(hour)")
                  .font(.system(size: 9))
                  .foregroundColor(.secondary)
              } else {
                Color.clear.frame(height: 11)
              }
            }
            .frame(maxWidth: .infinity)
          }
        }
      }
    }
  }
}
