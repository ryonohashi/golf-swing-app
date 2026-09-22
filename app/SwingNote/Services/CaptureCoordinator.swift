import Foundation
import Observation
import SwiftData

struct FlashEvent: Identifiable, Equatable {
    let id = UUID()
    /// 今日の本数
    let count: Int
}

/// 撮影サービスから届いたクリップを SwiftData に取り込み、フラッシュを出す。
@MainActor
@Observable
final class CaptureCoordinator {
    let service: any CaptureService
    private(set) var flash: FlashEvent?

    @ObservationIgnored private let analysis: any SwingAnalysisProvider
    @ObservationIgnored private var context: ModelContext?

    init(service: any CaptureService, analysis: any SwingAnalysisProvider) {
        self.service = service
        self.analysis = analysis
        service.onClip = { [weak self] clip in
            self?.receive(clip)
        }
    }

    /// 撮影画面が表示されている間だけ撮る
    func start(context: ModelContext) {
        self.context = context
        service.start(mode: AppPreferences.captureMode, angle: AppPreferences.cameraAngle)
    }

    func stop() {
        service.stop()
    }

    func dismissFlash() {
        flash = nil
    }

    private func receive(_ clip: CapturedClip) {
        guard let context else { return }
        let swing = SwingLibrary.ingest(
            clip,
            club: AppPreferences.currentClub,
            angle: AppPreferences.cameraAngle,
            context: context
        )
        // 番号はセッション内の通し番号なので、そのまま今日の本数になる
        flash = FlashEvent(count: swing.number)

        let input = AnalysisInput(clipURL: swing.clipURL, impactTime: swing.impactTime, duration: swing.duration, seed: swing.number)
        let provider = self.analysis
        Task {
            let result = await provider.analyze(input)
            SwingLibrary.apply(result, to: swing, context: context)
        }
    }
}

extension CaptureCoordinator {
    /// アプリ本体用。カメラ撮影の実装は POC 通過後に差し替える
    static func live() -> CaptureCoordinator {
        CaptureCoordinator(service: MockCaptureService(simulatesSwings: false), analysis: MockSwingAnalysisProvider())
    }

    /// プレビュー用。一定間隔でスイングを保存する
    static func preview() -> CaptureCoordinator {
        CaptureCoordinator(service: MockCaptureService(simulatesSwings: true, interval: .seconds(5)), analysis: MockSwingAnalysisProvider())
    }
}
