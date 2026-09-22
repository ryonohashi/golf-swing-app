import AVFoundation
import SwiftUI

/// 実験用の画面。製品UIではない。
/// 計測中は画面を暗くし、実打と判定した回数だけを大きく出す（プレビューはタップで切り替え）。
struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @State private var showsPreview = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if showsPreview || !recorder.isRunning {
                CameraPreview(session: recorder.session)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                    .overlay { RoiOverlay(roi: recorder.config.roi) }
            }

            VStack(spacing: 16) {
                Text("\(recorder.hitCount)")
                    .font(.system(size: 160, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .shadow(radius: 8)

                Spacer()

                meters
                Text(recorder.statusText)
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                HStack(spacing: 12) {
                    Button(showsPreview ? "プレビューを消す" : "プレビュー") {
                        showsPreview.toggle()
                    }
                    .buttonStyle(.bordered)
                    .frame(height: 60)

                    Button(recorder.isRunning ? "計測終了" : "計測開始") {
                        if recorder.isRunning { recorder.stop() } else { recorder.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.isRunning ? .red : .green)
                    .frame(height: 60)
                    .disabled(!recorder.isReady)
                }
                .font(.title3.bold())
            }
            .padding()
        }
        .task { await recorder.prepare() }
    }

    private var meters: some View {
        VStack(spacing: 8) {
            LevelBar(
                label: "音 \(Int(recorder.audioLevelDb)) dB",
                value: (recorder.audioLevelDb + 80) / 80,
                marker: (recorder.config.audioAbsoluteMinDb + 80) / 80,
                color: .orange)
            LevelBar(
                label: String(format: "動き %.3f", recorder.motionRatio),
                value: recorder.motionRatio / 0.5,
                marker: recorder.config.motionOnThreshold / 0.5,
                color: .cyan)
        }
    }
}

/// 0〜1 の値を横棒で出す。marker は閾値の位置
private struct LevelBar: View {
    let label: String
    let value: Double
    let marker: Double
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption.monospacedDigit()).foregroundStyle(.white)
            GeometryReader { geometry in
                let width = geometry.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(color).frame(width: width * min(max(value, 0), 1))
                    Rectangle().fill(.white).frame(width: 2).offset(x: width * min(max(marker, 0), 1))
                }
            }
            .frame(height: 10)
        }
    }
}

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
