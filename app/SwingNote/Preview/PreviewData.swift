import SwiftData
import SwiftUI

/// プレビュー用のダミーデータ。動画ファイルは持たないので、画面はプレースホルダで描かれる。
/// 今日：DR 8球（#1〜#8）→ 7I 12球（#9〜#20）、基準スイングは今日の #15。3日前：7I 10球。
@MainActor
enum PreviewData {
    static let container: ModelContainer = makeContainer(populated: true)
    static let emptyContainer: ModelContainer = makeContainer(populated: false)

    static var latest: Swing { swing(number: 20, daysAgo: 0) }
    static var base: Swing { swing(number: 15, daysAgo: 0) }
    /// 最新球とクラブが違う球（DR）
    static var driverSwing: Swing { swing(number: 6, daysAgo: 0) }

    static func swing(number: Int, daysAgo: Int) -> Swing {
        let sessions = (try? container.mainContext.fetch(FetchDescriptor<Session>())) ?? []
        let session = sessions.first {
            Calendar.current.isDate($0.startedAt, inSameDayAs: Date.now.addingTimeInterval(-Double(daysAgo) * 86_400))
        }
        guard let found = session?.swings.first(where: { $0.number == number }) else {
            fatalError("プレビューデータに #\(number) がありません")
        }
        return found
    }

    private static func makeContainer(populated: Bool) -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
        do {
            let container = try ModelContainer(for: Schema(SwingNoteSchema.models), configurations: [configuration])
            if populated { populate(container.mainContext) }
            return container
        } catch {
            fatalError("プレビュー用の SwiftData を作れませんでした: \(error)")
        }
    }

    private static func populate(_ context: ModelContext) {
        let now = Date.now
        let todayStart = Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: now) ?? now
        // 18時より前に開いた時もセッションが「今日」になるよう、現在時刻より前に寄せる
        let start = min(todayStart, now.addingTimeInterval(-20 * 90))
        let today = addSession(start: start, blocks: [(.driver, 8), (.iron7, 12)], context: context)
        _ = addSession(start: start.addingTimeInterval(-3 * 86_400), blocks: [(.iron7, 10)], context: context)

        if let base = today.swings.first(where: { $0.number == 15 }) {
            let pin = BaseSwingPin(swing: nil, pinnedAt: base.capturedAt.addingTimeInterval(120))
            context.insert(pin)
            pin.swing = base
        }
        try? context.save()
    }

    private static func addSession(start: Date, blocks: [(ClubTag, Int)], context: ModelContext) -> Session {
        let session = Session(startedAt: start)
        context.insert(session)
        let config = CaptureConfig.current
        var number = 0
        var time = start
        for (club, count) in blocks {
            let block = ClubBlock(club: club, startedAt: time)
            context.insert(block)
            block.session = session
            for _ in 0..<count {
                number += 1
                let swing = Swing(
                    number: number,
                    clipFileName: nil,
                    capturedAt: time,
                    club: club,
                    angle: .downTheLine,
                    duration: config.clipDuration,
                    impactTime: config.secondsBeforeImpact
                )
                context.insert(swing)
                swing.session = session
                swing.block = block
                let seed = number + Int(start.timeIntervalSince1970) % 1000
                let analysis = MockSwingAnalysisProvider.make(
                    AnalysisInput(clipURL: nil, impactTime: swing.impactTime, duration: swing.duration, seed: seed)
                )
                SwingLibrary.apply(analysis, to: swing, context: context)
                time = time.addingTimeInterval(90)
            }
        }
        return session
    }
}

extension View {
    /// プレビューに SwiftData・撮影モック・画面遷移・配色を入れる
    @MainActor
    func previewEnvironment(outdoor: Bool = false, empty: Bool = false) -> some View {
        NavigationStack {
            self
        }
        .modelContainer(empty ? PreviewData.emptyContainer : PreviewData.container)
        .environment(CaptureCoordinator.preview())
        .environment(Router())
        .themed(outdoor: outdoor)
    }
}
