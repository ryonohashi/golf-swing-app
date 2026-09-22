import Foundation
import SwiftData

/// よく使う取得条件。
enum SwingQueries {
    /// 最新球（全セッションで一番新しい1球）
    static var latestSwing: FetchDescriptor<Swing> {
        var descriptor = FetchDescriptor<Swing>(sortBy: [SortDescriptor(\.capturedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return descriptor
    }
}

/// クリップ動画の置き場所。すべて端末内。
enum ClipStorage {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Clips", directoryHint: .isDirectory)
    }

    /// 一時ファイルをライブラリへ移し、保存したファイル名を返す
    static func moveIntoLibrary(_ source: URL) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(UUID().uuidString).\(source.pathExtension.isEmpty ? "mov" : source.pathExtension)"
            try fileManager.moveItem(at: source, to: directory.appending(path: name))
            return name
        } catch {
            return nil
        }
    }
}

/// スイングの取り込みと基準スイングのピン留め。
@MainActor
enum SwingLibrary {
    static func currentSession(in context: ModelContext, at date: Date) -> Session? {
        var descriptor = FetchDescriptor<Session>(sortBy: [SortDescriptor(\.startedAt, order: .reverse)])
        descriptor.fetchLimit = 1
        guard let latest = try? context.fetch(descriptor).first,
              SessionRule.belongsToSameSession(sessionStart: latest.startedAt, date: date)
        else { return nil }
        return latest
    }

    /// 確定したクリップを1球として登録する。クラブは今のブロックから引き継ぐ
    @discardableResult
    static func ingest(_ clip: CapturedClip, club: ClubTag, angle: CameraAngle, context: ModelContext) -> Swing {
        let session: Session
        if let current = currentSession(in: context, at: clip.capturedAt) {
            session = current
        } else {
            session = Session(startedAt: clip.capturedAt)
            context.insert(session)
        }

        let lastBlock = session.blocks.max { $0.startedAt < $1.startedAt }
        let block: ClubBlock
        if let lastBlock, lastBlock.clubRaw == club.rawValue {
            block = lastBlock
        } else {
            block = ClubBlock(club: club, startedAt: clip.capturedAt)
            context.insert(block)
            block.session = session
        }

        let swing = Swing(
            number: session.swings.count + 1,
            clipFileName: clip.fileURL.flatMap(ClipStorage.moveIntoLibrary),
            capturedAt: clip.capturedAt,
            club: club,
            angle: angle,
            duration: clip.duration,
            impactTime: clip.impactTime
        )
        context.insert(swing)
        swing.session = session
        swing.block = block
        try? context.save()
        return swing
    }

    static func apply(_ analysis: SwingAnalysis, to swing: Swing, context: ModelContext) {
        swing.addressTime = analysis.checkpoints[.address]
        swing.topTime = analysis.checkpoints[.top]
        if swing.impactTime == nil { swing.impactTime = analysis.checkpoints[.impact] }
        swing.finishTime = analysis.checkpoints[.finish]
        swing.headShiftPercent = analysis.metrics.headShiftPercent
        swing.shoulderTurnDegrees = analysis.metrics.shoulderTurnDegrees
        swing.hipSwayPercent = analysis.metrics.hipSwayPercent
        swing.bodyTiltDegrees = analysis.metrics.bodyTiltDegrees
        swing.tempoRatio = analysis.metrics.tempoRatio
        try? context.save()
    }

    /// ユーザーが選んだ1球を基準スイングにする。v1 は1本だけなので、前の基準は置き換わる
    static func pinAsBase(_ swing: Swing, context: ModelContext) {
        let pins = (try? context.fetch(FetchDescriptor<BaseSwingPin>())) ?? []
        let pin: BaseSwingPin
        if let existing = pins.first {
            pin = existing
        } else {
            pin = BaseSwingPin(swing: nil)
            context.insert(pin)
        }
        for extra in pins.dropFirst() { context.delete(extra) }
        pin.swing = swing
        pin.pinnedAt = .now
        try? context.save()
    }
}
