import Foundation
import Observation

/// 撮影の状態。撮影画面の右上に出す。
enum CaptureStatus: Equatable {
    case stopped
    /// 自動：リングバッファで撮りながらスイング候補を待っている
    case waiting
    /// 自動：動き検出でスイング候補が出た。時間窓内のインパクト音を待っている
    case swingCandidate
    /// 実打と確定し、クリップを切り出している
    case saving
    /// 一定時間スイング候補がなく、省電力状態に落ちている
    case powerSaving
    /// 手動：録画ボタン待ち
    case manualReady
    /// 手動：録画中
    case manualRecording
    case unavailable(String)

    var label: String {
        switch self {
        case .stopped: "停止中"
        case .waiting: "待機中"
        case .swingCandidate: "スイング候補"
        case .saving: "保存中"
        case .powerSaving: "省電力"
        case .manualReady: "手動"
        case .manualRecording: "録画中"
        case .unavailable(let reason): reason
        }
    }
}

/// 1球ぶんのクリップが確定したことの通知。
struct CapturedClip {
    /// 一時ファイル。取り込み時にライブラリへ移す。モックでは nil
    var fileURL: URL?
    var capturedAt: Date
    /// クリップ先頭からインパクトまでの秒。手動録画では分からないので nil
    var impactTime: Double?
    var duration: Double
}

/// 撮影の窓口。実装は POC-01（動作＋音の判定）と POC-02（リングバッファ）の結果を組み込んで後から差し替える。
@MainActor
protocol CaptureService: AnyObject {
    var status: CaptureStatus { get }
    /// 今バッファに書いているフレームレート。発熱で落とした時はここが変わる
    var frameRate: Int { get }
    /// クリップが確定するたびに呼ばれる
    var onClip: ((CapturedClip) -> Void)? { get set }

    func start(mode: CaptureMode, angle: CameraAngle)
    func stop()
    /// 手動モードの録画開始／終了
    func toggleManualRecording()
}

/// カメラを使わないモック。simulatesSwings が true なら一定間隔でスイング候補と保存を繰り返す。
@MainActor
@Observable
final class MockCaptureService: CaptureService {
    private(set) var status: CaptureStatus = .stopped
    let frameRate = CaptureConfig.current.frameRate
    @ObservationIgnored var onClip: ((CapturedClip) -> Void)?

    @ObservationIgnored private let simulatesSwings: Bool
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var mode: CaptureMode = .auto
    @ObservationIgnored private var manualStartedAt: Date?

    init(simulatesSwings: Bool, interval: Duration = .seconds(8)) {
        self.simulatesSwings = simulatesSwings
        self.interval = interval
    }

    func start(mode: CaptureMode, angle: CameraAngle) {
        stop()
        self.mode = mode
        status = mode == .auto ? .waiting : .manualReady
        guard simulatesSwings, mode == .auto else { return }
        loop = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: self?.interval ?? .seconds(8))
                guard !Task.isCancelled, let self else { return }
                count += 1
                // 4回に1回は素振り（インパクト音なし）として候補を捨てる
                await self.runCandidate(hit: count % 4 != 0)
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        manualStartedAt = nil
        status = .stopped
    }

    func toggleManualRecording() {
        guard mode == .manual else { return }
        if status == .manualRecording, let startedAt = manualStartedAt {
            manualStartedAt = nil
            status = .manualReady
            onClip?(CapturedClip(fileURL: nil, capturedAt: .now, impactTime: nil, duration: Date.now.timeIntervalSince(startedAt)))
        } else {
            manualStartedAt = .now
            status = .manualRecording
        }
    }

    /// 開発用：実打を1回起こす
    func simulateHit() {
        guard mode == .auto, status == .waiting else { return }
        Task { await runCandidate(hit: true) }
    }

    private func runCandidate(hit: Bool) async {
        status = .swingCandidate
        try? await Task.sleep(for: .seconds(1.2))
        guard !Task.isCancelled, status == .swingCandidate else { return }
        if hit {
            status = .saving
            try? await Task.sleep(for: .seconds(0.4))
            let config = CaptureConfig.current
            onClip?(CapturedClip(fileURL: nil, capturedAt: .now, impactTime: config.secondsBeforeImpact, duration: config.clipDuration))
        }
        status = .waiting
    }
}
