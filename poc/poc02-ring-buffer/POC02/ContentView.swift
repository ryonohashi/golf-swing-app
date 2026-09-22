import AVFoundation
import SwiftUI

/// 実験用の画面。製品UIではない。
/// 保存できたクリップ数を大きく出し、その下に直近の所要時間とディスク使用量を出す。
struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @State private var showsPreview = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showsPreview || !recorder.isRunning {
                CameraPreview(session: recorder.session)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay { RoiOverlay(roi: recorder.detectionConfig.roi) }
            }

            VStack(spacing: 12) {
                Text("\(recorder.clipCount)")
                    .font(.system(size: 140, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(radius: 8)

                Spacer()

                stats
                Text(recorder.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button("手動トリガ") { recorder.manualTrigger() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .disabled(!recorder.isRunning)

                    Button(recorder.intervalEnabled
                           ? "間隔トリガ 停止"
                           : "間隔トリガ \(Int(recorder.config.intervalTriggerSeconds))秒") {
                        recorder.setIntervalEnabled(!recorder.intervalEnabled)
                    }
                    .buttonStyle(.bordered)
                    .tint(recorder.intervalEnabled ? .yellow : .white)
                }
                .frame(height: 50)

                HStack(spacing: 12) {
                    Button(showsPreview ? "プレビューを消す" : "プレビュー") {
                        showsPreview.toggle()
                    }
                    .buttonStyle(.bordered)

                    Button(recorder.isRunning ? "計測終了" : "計測開始") {
                        if recorder.isRunning { recorder.stop() } else { recorder.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRunning ? .red : .green)
                    .disabled(!recorder.isReady)
                }
                .frame(height: 60)
            }
            .font(.title3.bold())
            .padding()
        }
        .task { await recorder.prepare() }
    }

    private var stats: some View {
        let latency = recorder.lastLatency.map { String(format: "%.2f 秒", $0) } ?? "-"
        let disk = ByteCountFormatter.string(fromByteCount: recorder.diskBytes, countStyle: .file)
        return VStack(alignment: .leading, spacing: 4) {
            Text("直近の所要時間（インパクト→保存） \(latency)")
            Text("切り出し待ち \(recorder.pendingCount)　失敗 \(recorder.failedClipCount)")
            Text("チャンク \(recorder.chunkFiles) 個　使用量 \(disk)")
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 実打判定（POC-01）の動き検出の範囲。置き場所を決める時の目安
private struct RoiOverlay: View {
    let roi: [Double]

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Rectangle()
                .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .frame(width: size.width * (roi[2] - roi[0]), height: size.height * (roi[3] - roi[1]))
                .offset(x: size.width * roi[0], y: size.height * roi[1])
        }
        .allowsHitTesting(false)
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            // セッションの構成後に接続ができるので、レイアウトのたびに向きを合わせる
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }
    }
}
