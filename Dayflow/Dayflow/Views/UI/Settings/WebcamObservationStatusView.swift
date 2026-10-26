//
//  WebcamObservationStatusView.swift
//  Dayflow
//
//  Live camera preview + capture status for the experimental webcam
//  observation module. Preview renders locally via AVCaptureVideoPreviewLayer;
//  nothing here touches the analysis pipeline or storage.
//

import AVFoundation
import SwiftUI

struct WebcamObservationStatusView: View {
  let isEnabled: Bool
  @State private var snapshot: WebcamObserver.StatusSnapshot?
  @State private var session: AVCaptureSession?
  private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if isEnabled {
        CameraPreviewContainer(session: session)
          .frame(width: 260, height: 146)
          .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .stroke(Color.black.opacity(0.08), lineWidth: 1)
          )

        statusText
          .font(.custom("Figtree", size: 12))
          .foregroundColor(SettingsStyle.secondary)
      }
    }
    .onReceive(refresh) { _ in
      snapshot = WebcamObserver.shared.statusSnapshot()
      session = WebcamObserver.shared.previewSession()
    }
    .onAppear {
      snapshot = WebcamObserver.shared.statusSnapshot()
      session = WebcamObserver.shared.previewSession()
    }
  }

  @ViewBuilder
  private var statusText: some View {
    if let snapshot {
      if !snapshot.running, let error = snapshot.lastError {
        Text("未在采集：\(error)")
      } else if snapshot.running, let last = snapshot.lastCaptureAt {
        let faceLine =
          snapshot.lastFaceCount > 0
          ? "检测到人脸" : "画面中未检测到人脸"
        let time = Self.clock.string(from: last)
        Text("● 采集中 · \(faceLine) · 缓冲 \(snapshot.bufferedFrames) 帧 · 上次采样 \(time)")
      } else if snapshot.running {
        Text("● 已启动，等待第一次采样…")
      } else {
        Text("未在采集")
      }
    } else {
      Text("读取状态中…")
    }
  }

  private static let clock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
  }()
}

/// Bridges AVCaptureVideoPreviewLayer into SwiftUI.
struct CameraPreviewContainer: NSViewRepresentable {
  let session: AVCaptureSession?

  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    let preview = AVCaptureVideoPreviewLayer()
    preview.videoGravity = .resizeAspectFill
    preview.session = session
    view.layer = preview
    return view
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    if let layer = nsView.layer as? AVCaptureVideoPreviewLayer {
      layer.session = session
    }
  }
}
