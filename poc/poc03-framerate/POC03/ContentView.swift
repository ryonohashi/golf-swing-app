import AVFoundation
import Combine
import SwiftUI

/// 実験用の画面。製品UIではない。
/// 画面を暗くする設定の時は、計測中はプレビューを外して黒一色にする（タップで元に戻る）。
struct ContentView: View {
    @StateObject private var recorder = ThermalRecorder()
    @Environment(\.scenePhase) private var scenePhase
    private let clock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isDimmed: Bool { recorder.isRunning && recorder.config.dimScreen }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isDimmed {
                dimmedView
            } else {
                CameraPreview(session: recorder.session)
                    .aspectRatio(9.0 / 16.0, contentMode: .fit)
                controls
            }
        }
        .task { await recorder.prepare() }
        .onReceive(clock) { _ in recorder.tick() }
        .onChange(of: recorder.config.frameRate) { _, fps in recorder.frameRateChosen(fps) }
        .onChange(of: recorder.config.dimScreen) { _, on in recorder.dimChanged(on) }
        .onChange(of: scenePhase) { _, phase in recorder.sceneActiveChanged(phase == .active) }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            readings
            Spacer()
            Text(recorder.statusText)
                .font(.footnote)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Picker("fps", selection: $recorder.config.frameRate) {
                ForEach(recorder.config.frameRateChoices, id: \.self) { Text("\($0) fps").tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(recorder.isRunning)

            Toggle("計測中は画面を暗くする", isOn: $recorder.config.dimScreen)
            Toggle("動き検出（POC-01）を回す", isOn: $recorder.config.motionMeterEnabled)
                .disabled(recorder.isRunning)

            Button(recorder.isRunning ? "計測終了" : "計測開始") {
                if recorder.isRunning { recorder.stop() } else { recorder.start() }
            }
            .buttonStyle(.borderedProminent)
            .tint(recorder.isRunning ? .red : .green)
            .font(.title3.bold())
            .frame(height: 60)
            .disabled(!recorder.isReady)
        }
        .foregroundStyle(.white)
        .padding()
    }

    private var readings: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Self.clockText(recorder.elapsedSeconds))
                .font(.system(size: 56, weight: .heavy, design: .rounded))
            Text("発熱 \(recorder.thermalState.label)　電池 \(Self.batteryText(recorder.batteryLevel))")
            Text("設定 \(recorder.currentFrameRate) fps　実測 \(String(format: "%.1f", recorder.deliveredFps)) fps")
        }
        .font(.headline)
        .monospacedDigit()
        .foregroundStyle(.white)
        .shadow(radius: 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 黒一色。有機ELでは黒の画素はほぼ電力を使わない。時刻だけ暗く出す
    private var dimmedView: some View {
        Text("\(Self.clockText(recorder.elapsedSeconds))　\(recorder.thermalState.label)\nタップで表示")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.25))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { recorder.config.dimScreen = false }
    }

    private static func clockText(_ seconds: Double) -> String {
        let total = Int(seconds)
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    private static func batteryText(_ level: Float) -> String {
        level < 0 ? "不明" : "\(Int((level * 100).rounded()))%"
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
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
