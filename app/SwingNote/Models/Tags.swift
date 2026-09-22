import Foundation

/// クラブのタグ。rawValue は保存用のキーを兼ねるので変えない。
enum ClubTag: String, CaseIterable, Identifiable {
    case driver = "DR"
    case wood3 = "3W"
    case wood5 = "5W"
    case utility = "UT"
    case iron4 = "4I"
    case iron5 = "5I"
    case iron6 = "6I"
    case iron7 = "7I"
    case iron8 = "8I"
    case iron9 = "9I"
    case pitchingWedge = "PW"
    case approachWedge = "AW"
    case sandWedge = "SW"

    var id: String { rawValue }
    var label: String { rawValue }
}

/// 撮影アングルのプリセット（spec-capture）。
enum CameraAngle: String, CaseIterable, Identifiable {
    case downTheLine
    case obliqueRear
    case faceOn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .downTheLine: "後方"
        case .obliqueRear: "斜め後方"
        case .faceOn: "横・正面"
        }
    }
}

/// 撮影モード。普段は自動のまま使い、手動は設定からだけ切り替える。
enum CaptureMode: String, CaseIterable, Identifiable {
    case auto
    case manual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: "自動"
        case .manual: "手動"
        }
    }

    var detail: String {
        switch self {
        case .auto: "スイング動作と打球音がそろった時に保存"
        case .manual: "検出がうまくいかない時の予備"
        }
    }
}

/// 4コマ比較で並べる4点。
enum Checkpoint: Int, CaseIterable, Identifiable {
    case address
    case top
    case impact
    case finish

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .address: "アドレス"
        case .top: "トップ"
        case .impact: "インパクト"
        case .finish: "フィニッシュ"
        }
    }
}

/// 表示できる身体の動きの値。フェース角・打点は2D映像に映らないので持たない。
enum MetricKind: CaseIterable, Identifiable {
    case headShift
    case shoulderTurn
    case hipSway
    case bodyTilt
    case tempo

    var id: Self { self }

    var label: String {
        switch self {
        case .headShift: "頭の移動（左右）"
        case .shoulderTurn: "肩の回転（トップ）"
        case .hipSway: "腰のスウェー"
        case .bodyTilt: "体の傾き（アドレス）"
        case .tempo: "テンポ（上げ:下ろし）"
        }
    }

    func format(_ value: Double?) -> String {
        guard let value else { return "—" }
        switch self {
        case .headShift, .hipSway: return String(format: "%.1f%%", value)
        case .shoulderTurn, .bodyTilt: return String(format: "%.0f°", value)
        case .tempo: return String(format: "%.1f : 1", value)
        }
    }
}

struct BodyMotionMetrics: Equatable, Sendable {
    /// 身長に対する割合（%）
    var headShiftPercent: Double?
    var shoulderTurnDegrees: Double?
    /// 身長に対する割合（%）
    var hipSwayPercent: Double?
    var bodyTiltDegrees: Double?
    /// バックスイング時間 ÷ ダウンスイング時間
    var tempoRatio: Double?

    subscript(kind: MetricKind) -> Double? {
        switch kind {
        case .headShift: headShiftPercent
        case .shoulderTurn: shoulderTurnDegrees
        case .hipSway: hipSwayPercent
        case .bodyTilt: bodyTiltDegrees
        case .tempo: tempoRatio
        }
    }
}
