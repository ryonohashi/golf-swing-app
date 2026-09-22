import Foundation

struct AnalysisInput: Sendable {
    var clipURL: URL?
    /// 撮影時に分かっているインパクト時刻（クリップ先頭からの秒）
    var impactTime: Double?
    var duration: Double
    var seed: Int
}

/// 1球から取り出す値。身体の動きの値と、4コマに使うチェックポイントの時刻だけ。
/// 良し悪しの判定は持たない。
struct SwingAnalysis: Sendable {
    var checkpoints: [Checkpoint: Double]
    var metrics: BodyMotionMetrics
}

/// 姿勢推定の窓口。実装は Vision（VNDetectHumanBodyPoseRequest）で後から差し替える。
protocol SwingAnalysisProvider: Sendable {
    func analyze(_ input: AnalysisInput) async -> SwingAnalysis
}

/// ダミー値を返すモック。同じ seed なら同じ値になる。
struct MockSwingAnalysisProvider: SwingAnalysisProvider {
    func analyze(_ input: AnalysisInput) async -> SwingAnalysis {
        Self.make(input)
    }

    static func make(_ input: AnalysisInput) -> SwingAnalysis {
        var random = SeededRandom(seed: UInt64(truncatingIfNeeded: input.seed))
        let impact = input.impactTime ?? min(CaptureConfig.current.secondsBeforeImpact, input.duration)
        func clamp(_ value: Double) -> Double { min(max(value, 0), input.duration) }

        let checkpoints: [Checkpoint: Double] = [
            .address: clamp(impact - 2.4 + random.next(in: -0.3...0.3)),
            .top: clamp(impact - 0.28 + random.next(in: -0.04...0.04)),
            .impact: impact,
            .finish: clamp(impact + 1.2 + random.next(in: -0.2...0.2)),
        ]
        let metrics = BodyMotionMetrics(
            headShiftPercent: random.next(in: 1.5...5.0),
            shoulderTurnDegrees: random.next(in: 78...95).rounded(),
            hipSwayPercent: random.next(in: 1.0...4.5),
            bodyTiltDegrees: random.next(in: 30...38).rounded(),
            tempoRatio: random.next(in: 2.5...3.3)
        )
        return SwingAnalysis(checkpoints: checkpoints, metrics: metrics)
    }
}

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next() * (range.upperBound - range.lowerBound)
    }
}
