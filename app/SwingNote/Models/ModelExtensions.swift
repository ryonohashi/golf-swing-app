import Foundation

extension Swing {
    var club: ClubTag { ClubTag(rawValue: clubRaw) ?? .iron7 }
    var angle: CameraAngle { CameraAngle(rawValue: angleRaw) ?? .downTheLine }

    var clipURL: URL? {
        clipFileName.map { ClipStorage.directory.appending(path: $0) }
    }

    var displayNumber: String { "#\(number)" }

    /// 一覧のサムネイルに出す長さ。例 "0:08"
    var durationText: String {
        let seconds = Int(duration.rounded())
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    func time(of checkpoint: Checkpoint) -> Double? {
        switch checkpoint {
        case .address: addressTime
        case .top: topTime
        case .impact: impactTime
        case .finish: finishTime
        }
    }

    var metrics: BodyMotionMetrics {
        BodyMotionMetrics(
            headShiftPercent: headShiftPercent,
            shoulderTurnDegrees: shoulderTurnDegrees,
            hipSwayPercent: hipSwayPercent,
            bodyTiltDegrees: bodyTiltDegrees,
            tempoRatio: tempoRatio
        )
    }

    /// 再生・静止画の取り出しに必要な値だけを写し取ったもの
    var clipInfo: ClipInfo {
        var checkpoints: [Checkpoint: Double] = [:]
        for checkpoint in Checkpoint.allCases {
            if let time = time(of: checkpoint) { checkpoints[checkpoint] = time }
        }
        return ClipInfo(
            url: clipURL,
            duration: duration,
            impact: impactTime ?? min(CaptureConfig.current.secondsBeforeImpact, duration),
            checkpoints: checkpoints,
            seed: number
        )
    }
}

/// 比較画面が扱うクリップの情報。SwiftData のモデルから切り離して持つ。
struct ClipInfo: Equatable {
    let url: URL?
    let duration: Double
    /// クリップ先頭からインパクトまでの秒。2球はここを揃えて再生する
    let impact: Double
    /// クリップ先頭からの秒
    let checkpoints: [Checkpoint: Double]
    /// プレースホルダの見た目を球ごとに少し変えるための値
    let seed: Int
}

struct ClubGroup: Identifiable {
    let club: ClubTag
    /// 新しい順
    let swings: [Swing]
    var id: String { club.rawValue }
}

extension Session {
    var isToday: Bool { Calendar.current.isDateInToday(startedAt) }

    var title: String {
        isToday ? "今日の練習" : "\(DateText.monthDay(startedAt))の練習"
    }

    /// 例 "9月23日・20球・7I 12球 / DR 8球"。自動集計のみで手入力は求めない
    var summaryText: String {
        let perClub = clubGroups.map { "\($0.club.label) \($0.swings.count)球" }.joined(separator: " / ")
        return "\(DateText.monthDay(startedAt))・\(swings.count)球・\(perClub)"
    }

    /// クラブごとにまとめる。最後に打ったクラブが先頭
    var clubGroups: [ClubGroup] {
        let grouped = Dictionary(grouping: swings, by: \.clubRaw)
        return grouped
            .map { raw, swings in
                ClubGroup(
                    club: ClubTag(rawValue: raw) ?? .iron7,
                    swings: swings.sorted { $0.number > $1.number }
                )
            }
            .sorted { lhs, rhs in
                (lhs.swings.first?.capturedAt ?? .distantPast) > (rhs.swings.first?.capturedAt ?? .distantPast)
            }
    }
}

enum DateText {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M月d日"
        return formatter
    }()

    private static let shortFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    private static let fullFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy年M月d日 H:mm"
        return formatter
    }()

    static func monthDay(_ date: Date) -> String { monthDayFormatter.string(from: date) }
    static func short(_ date: Date) -> String { shortFormatter.string(from: date) }
    static func full(_ date: Date) -> String { fullFormatter.string(from: date) }
}
