import Foundation
import SwiftData

/// 練習1回ぶん。同じセッションかどうかは SessionRule で決める。
@Model
final class Session {
    var startedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Swing.session)
    var swings: [Swing] = []

    /// クラブを変えた区切り。ブロック内のスイングには同じクラブが自動で付く
    @Relationship(deleteRule: .cascade, inverse: \ClubBlock.session)
    var blocks: [ClubBlock] = []

    init(startedAt: Date) {
        self.startedAt = startedAt
    }
}

/// 同じクラブで続けて打った区間。クラブを変えた後の最初の1球で新しいブロックが始まる。
@Model
final class ClubBlock {
    var clubRaw: String
    var startedAt: Date
    var session: Session?

    @Relationship(deleteRule: .nullify, inverse: \Swing.block)
    var swings: [Swing] = []

    init(club: ClubTag, startedAt: Date) {
        self.clubRaw = club.rawValue
        self.startedAt = startedAt
    }

    var club: ClubTag { ClubTag(rawValue: clubRaw) ?? .iron7 }
}

/// 1球＝1クリップ。
@Model
final class Swing {
    /// セッション内の通し番号（1から）
    var number: Int
    /// Application Support/Clips/ 以下のファイル名。コンテナの場所は起動ごとに変わりうるのでフルパスは持たない
    var clipFileName: String?
    var capturedAt: Date
    var clubRaw: String
    var angleRaw: String
    /// クリップの長さ（秒）
    var duration: Double

    // チェックポイント。クリップ先頭からの秒。インパクトは撮影時に決まり、残りは姿勢推定で埋まる
    var addressTime: Double?
    var topTime: Double?
    var impactTime: Double?
    var finishTime: Double?

    // 身体の動きの値。姿勢推定が済むまでは nil
    var headShiftPercent: Double?
    var shoulderTurnDegrees: Double?
    var hipSwayPercent: Double?
    var bodyTiltDegrees: Double?
    var tempoRatio: Double?

    var session: Session?
    var block: ClubBlock?

    @Relationship(deleteRule: .nullify, inverse: \BaseSwingPin.swing)
    var basePin: BaseSwingPin?

    init(
        number: Int,
        clipFileName: String?,
        capturedAt: Date,
        club: ClubTag,
        angle: CameraAngle,
        duration: Double,
        impactTime: Double?
    ) {
        self.number = number
        self.clipFileName = clipFileName
        self.capturedAt = capturedAt
        self.clubRaw = club.rawValue
        self.angleRaw = angle.rawValue
        self.duration = duration
        self.impactTime = impactTime
    }
}

/// 基準スイングのピン留め。slot に一意制約をかけ、行が1つしか存在できないようにする（v1 は基準スイング1本）。
/// 基準スイングはアプリが選んだ球ではなく、ユーザーが比較の基準として選んだ球。
@Model
final class BaseSwingPin {
    @Attribute(.unique) var slot: String = "base"
    var swing: Swing?
    var pinnedAt: Date

    init(swing: Swing?, pinnedAt: Date = .now) {
        self.swing = swing
        self.pinnedAt = pinnedAt
    }
}

enum SwingNoteSchema {
    static let models: [any PersistentModel.Type] = [Session.self, ClubBlock.self, Swing.self, BaseSwingPin.self]
}
