import Foundation
@testable import HitDetectionCore

struct AudioRow {
    let t: Double
    let peakDb: Double
    let highPassPeakDb: Double
}

struct MotionRow {
    let t: Double
    let cells: [Double]
}

/// 判定器に通した結果。tools/replay.py の Run に相当する
struct DetectorRun {
    var peaks: [AudioPeak] = []
    var segments: [(segment: MotionSegment, qualified: Bool)] = []
    /// reportedAt は、その実打のイベントが出た時点で渡していた行の時刻（finish() で出たものは nil）
    var hits: [(impact: AudioPeak, segment: MotionSegment, reportedAt: Double?)] = []

    /// 音のブロックと動きの行を、実機と同じく時刻順に混ぜて判定器に渡す。同時刻なら音を先にする
    static func feed(config: DetectionConfig, audio: [AudioRow], motion: [MotionRow]) -> DetectorRun {
        let detector = HitDetector(config: config)
        var run = DetectorRun()
        var a = 0
        var m = 0
        while a < audio.count || m < motion.count {
            if m >= motion.count || (a < audio.count && audio[a].t <= motion[m].t) {
                let row = audio[a]
                a += 1
                run.record(detector.addAudio(t: row.t, peakDb: row.peakDb, highPassPeakDb: row.highPassPeakDb), at: row.t)
            } else {
                let row = motion[m]
                m += 1
                run.record(detector.addMotion(t: row.t, cellRatios: row.cells), at: row.t)
            }
        }
        run.record(detector.finish(), at: nil)
        return run
    }

    private mutating func record(_ events: [DetectorEvent], at t: Double?) {
        for event in events {
            switch event {
            case .audioPeak(let peak):
                peaks.append(peak)
            case .segment(let segment, let qualified):
                segments.append((segment, qualified))
            case .hit(let impact, let segment):
                hits.append((impact, segment, t))
            }
        }
    }
}

/// tools/test_replay.py の Scenario と同じ合成セッション。
/// 音は環境音 -60dB に打球音（30ms）を足し、動きは全セルに同じ値を入れる。
struct Scenario {
    private var sounds: [(t: Double, level: Double)] = []
    private var motions: [(start: Double, end: Double, ratio: Double)] = []

    func impact(_ t: Double, level: Double = -10, secondPeakAfter: Double? = nil) -> Scenario {
        var s = self
        s.sounds.append((t, level))
        if let secondPeakAfter {
            s.sounds.append((t + secondPeakAfter, level - 6))
        }
        return s
    }

    func motion(_ start: Double, _ end: Double, _ ratio: Double) -> Scenario {
        var s = self
        s.motions.append((start, end, ratio))
        return s
    }

    func swing(
        _ start: Double, impactAfter: Double = 1.2, length: Double = 2.0,
        level: Double = -10, secondPeakAfter: Double? = nil
    ) -> Scenario {
        motion(start, start + length, 0.3)
            .impact(start + impactAfter, level: level, secondPeakAfter: secondPeakAfter)
    }

    func run(_ config: DetectionConfig = .default, duration: Double = 40) -> DetectorRun {
        let audio = (0..<Int(duration / 0.01)).map { i -> AudioRow in
            let t = Double(i) * 0.01
            var level = -60.0
            for sound in sounds where sound.t <= t && t < sound.t + 0.03 {
                level = max(level, sound.level)
            }
            return AudioRow(t: t, peakDb: level, highPassPeakDb: level)
        }
        let cellCount = config.motionGridCols * config.motionGridRows
        let motion = (1..<Int(duration * 60)).map { i -> MotionRow in
            let t = Double(i) / 60
            var ratio = 0.005
            for m in motions where m.start <= t && t <= m.end {
                ratio = max(ratio, m.ratio)
            }
            return MotionRow(t: t, cells: Array(repeating: ratio, count: cellCount))
        }
        return DetectorRun.feed(config: config, audio: audio, motion: motion)
    }
}
