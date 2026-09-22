import Foundation

// 実打の判定（スイング動作＋インパクト音のAND）。
// tools/replay.py に同じロジックがある。片方を変えたらもう片方も合わせること。

struct AudioPeak {
    let t: Double
    let level: Double
}

struct MotionSegment {
    let start: Double
    let end: Double
    let peak: Double

    var duration: Double { end - start }
}

enum DetectorEvent {
    case audioPeak(AudioPeak)
    case segment(MotionSegment, qualified: Bool)
    case hit(impact: AudioPeak, segment: MotionSegment)
}

/// 環境音の床からの突出でインパクト音の候補を拾う
struct AudioPeakDetector {
    let config: DetectionConfig
    private var floor: Double?
    private var lastEventT = -Double.infinity

    init(config: DetectionConfig) {
        self.config = config
    }

    mutating func add(t: Double, level: Double) -> AudioPeak? {
        let floor = self.floor ?? level
        let threshold = floor + config.audioRelativeThresholdDb
        let above = level >= threshold && level >= config.audioAbsoluteMinDb
        let fire = above && t - lastEventT >= config.audioDebounceSeconds
        if level < threshold {
            let alpha = min(1, config.audioBlockSeconds / config.audioFloorTauSeconds)
            self.floor = floor + alpha * (level - floor)
        } else {
            self.floor = floor
        }
        guard fire else { return nil }
        lastEventT = t
        return AudioPeak(t: t, level: level)
    }
}

/// ROI内の動き量をヒステリシスで区間に切る
struct MotionSegmenter {
    let config: DetectionConfig
    private var start: Double?
    private var peak = 0.0
    private var lastAbove = 0.0

    init(config: DetectionConfig) {
        self.config = config
    }

    mutating func add(t: Double, ratio: Double) -> MotionSegment? {
        guard let start else {
            if ratio >= config.motionOnThreshold {
                self.start = t
                peak = ratio
                lastAbove = t
            }
            return nil
        }
        peak = max(peak, ratio)
        if ratio >= config.motionOffThreshold {
            lastAbove = t
            return nil
        }
        guard t - lastAbove >= config.motionOffHoldSeconds else { return nil }
        self.start = nil
        return MotionSegment(start: start, end: lastAbove, peak: peak)
    }

    mutating func finish() -> MotionSegment? {
        guard let start else { return nil }
        self.start = nil
        return MotionSegment(start: start, end: lastAbove, peak: peak)
    }
}

final class HitDetector {
    let config: DetectionConfig
    private let roiCells: [Int]
    private var audio: AudioPeakDetector
    private var motion: MotionSegmenter
    /// まだどのスイング候補にも使われていないインパクト音の候補（時刻順）
    private var peaks: [AudioPeak] = []
    /// 終わったが、後ろの時間窓ぶんの音がまだ揃っていないスイング候補
    private var pendingSegments: [MotionSegment] = []
    private var latestAudioT = -Double.infinity
    private var latestVideoT = -Double.infinity

    init(config: DetectionConfig) {
        self.config = config
        roiCells = config.roiCells()
        audio = AudioPeakDetector(config: config)
        motion = MotionSegmenter(config: config)
    }

    static func roiRatio(_ cells: [Double], roiCells: [Int]) -> Double {
        guard !roiCells.isEmpty else { return 0 }
        return roiCells.reduce(0) { $0 + cells[$1] } / Double(roiCells.count)
    }

    func isSwingCandidate(_ s: MotionSegment) -> Bool {
        s.duration >= config.minSwingSeconds
            && s.duration <= config.maxSwingSeconds
            && s.peak >= config.minSwingPeak
    }

    func addAudio(t: Double, peakDb: Double, highPassPeakDb: Double) -> [DetectorEvent] {
        latestAudioT = t
        var events: [DetectorEvent] = []
        let level = config.useHighPass ? highPassPeakDb : peakDb
        if let peak = audio.add(t: t, level: level) {
            peaks.append(peak)
            events.append(.audioPeak(peak))
        }
        events += judgeReady(now: min(latestAudioT, latestVideoT))
        return events
    }

    func addMotion(t: Double, cellRatios: [Double]) -> [DetectorEvent] {
        latestVideoT = t
        var events: [DetectorEvent] = []
        let ratio = HitDetector.roiRatio(cellRatios, roiCells: roiCells)
        if let segment = motion.add(t: t, ratio: ratio) {
            let qualified = isSwingCandidate(segment)
            events.append(.segment(segment, qualified: qualified))
            if qualified { pendingSegments.append(segment) }
        }
        events += judgeReady(now: min(latestAudioT, latestVideoT))
        return events
    }

    func finish() -> [DetectorEvent] {
        var events: [DetectorEvent] = []
        if let segment = motion.finish() {
            let qualified = isSwingCandidate(segment)
            events.append(.segment(segment, qualified: qualified))
            if qualified { pendingSegments.append(segment) }
        }
        events += judgeReady(now: .infinity)
        return events
    }

    private func judgeReady(now: Double) -> [DetectorEvent] {
        var events: [DetectorEvent] = []
        while let segment = pendingSegments.first,
              segment.end + config.windowAfterEndSeconds <= now {
            pendingSegments.removeFirst()
            let lo = segment.start - config.windowBeforeStartSeconds
            let hi = segment.end + config.windowAfterEndSeconds
            let inWindow = peaks.indices.filter { peaks[$0].t >= lo && peaks[$0].t <= hi }
            // 窓内に複数あれば一番大きい音をインパクトとする（端末から2mの自分の打球が最も大きい想定）
            guard let best = inWindow.max(by: { peaks[$0].level < peaks[$1].level }) else { continue }
            let impact = peaks.remove(at: best)
            events.append(.hit(impact: impact, segment: segment))
        }
        if now.isFinite {
            peaks.removeAll { $0.t < now - 30 }
        }
        return events
    }
}
