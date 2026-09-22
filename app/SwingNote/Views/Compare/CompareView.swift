import SwiftData
import SwiftUI

enum CompareTab: Hashable {
    /// 縦向きで同じアングルなら重ね合わせ、それ以外は横並び
    case video
    case fourFrames
}

enum VideoLayout: Equatable {
    case overlay
    case sideBySide
}

/// 比べる2球の組み合わせから、既定の表示と注意書きを決める（spec-compare 比較の種類と既定の表示方法）
struct SwingPairing {
    let sameClub: Bool
    let sameAngle: Bool
    let sameDay: Bool

    init(a: Swing, b: Swing) {
        sameClub = a.clubRaw == b.clubRaw
        sameAngle = a.angleRaw == b.angleRaw
        sameDay = Calendar.current.isDate(a.capturedAt, inSameDayAs: b.capturedAt)
    }

    /// 異なるクラブは「横並び＋チェックポイント静止画」が既定なので4コマから開く
    var defaultTab: CompareTab { sameClub ? .video : .fourFrames }

    var notes: [String] {
        var notes: [String] = []
        if !sameClub {
            notes.append("クラブが違う2球です。アドレスの幅とボール位置の違いは、クラブによる正常な差です。")
        }
        if !sameAngle {
            notes.append("撮影アングルが違うため、重ね合わせではなく横並びで表示します。")
        }
        return notes
    }
}

/// 04 重ね合わせ比較 / 05 4コマ比較。縦＝重ね合わせ、横＝横並び。
/// 示すのは身体の動きの差分だけで、どちらが良いかは表示しない。
struct CompareView: View {
    let swingA: Swing
    let swingB: Swing

    @Environment(\.theme) private var theme
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Query(SwingQueries.latestSwing) private var latestSwings: [Swing]
    @Query private var pins: [BaseSwingPin]

    @State private var tab: CompareTab
    @State private var playback: ComparePlayback
    @State private var overlayOpacity = UIConfig.defaultOverlayOpacity
    @State private var overlayOffset = 0.0
    @State private var showExportDialog = false
    @State private var exportMessage: String?

    init(swingA: Swing, swingB: Swing) {
        self.swingA = swingA
        self.swingB = swingB
        _tab = State(initialValue: SwingPairing(a: swingA, b: swingB).defaultTab)
        _playback = State(initialValue: ComparePlayback(a: swingA.clipInfo, b: swingB.clipInfo))
    }

    private var pairing: SwingPairing { SwingPairing(a: swingA, b: swingB) }
    private var isLandscape: Bool { verticalSizeClass == .compact }
    private var videoLayout: VideoLayout {
        (isLandscape || !pairing.sameAngle) ? .sideBySide : .overlay
    }

    var body: some View {
        Group {
            if isLandscape {
                landscapeBody
            } else {
                portraitBody
            }
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { OrientationLock.allowLandscape() }
        .onDisappear {
            playback.teardown()
            OrientationLock.portraitOnly()
        }
        .task(id: videoLayout) {
            await playback.load(tinted: videoLayout == .overlay)
        }
        .confirmationDialog("カメラロールに保存", isPresented: $showExportDialog, titleVisibility: .visible) {
            ForEach([swingA, swingB]) { swing in
                if let url = swing.clipURL {
                    Button("\(legendTitle(swing))を保存") {
                        Task { await export(url) }
                    }
                }
            }
        } message: {
            if swingA.clipURL == nil && swingB.clipURL == nil {
                Text("保存できる動画がありません")
            }
        }
        .alert(
            exportMessage ?? "",
            isPresented: Binding(get: { exportMessage != nil }, set: { if !$0 { exportMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: 縦向き

    private var portraitBody: some View {
        VStack(spacing: 0) {
            HStack {
                BackButton()
                Spacer()
                tabPicker.frame(width: 200)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            legend
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            ScrollView {
                VStack(spacing: 12) {
                    notes
                    switch tab {
                    case .video:
                        videoStage
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.58 }
                        videoControls
                            .padding(.horizontal, 16)
                        metricsTable
                            .padding(.horizontal, 16)
                    case .fourFrames:
                        FourFrameComparison(a: playback.a, b: playback.b, isLandscape: false)
                            .padding(.horizontal, 16)
                        metricsTable
                            .padding(.horizontal, 16)
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: 横向き

    private var landscapeBody: some View {
        HStack(alignment: .top, spacing: 16) {
            Group {
                switch tab {
                case .video:
                    videoStage
                case .fourFrames:
                    FourFrameComparison(a: playback.a, b: playback.b, isLandscape: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        BackButton()
                        Spacer()
                        tabPicker
                    }
                    legend
                    notes
                    if tab == .video {
                        videoControls
                    }
                    metricsTable
                }
                .padding(.bottom, 16)
            }
            .scrollIndicators(.hidden)
            .frame(width: 320)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: 部品

    private var tabPicker: some View {
        SegmentedPill(
            options: [
                (value: CompareTab.video, label: videoLayout == .overlay ? "重ね合わせ" : "横並び"),
                (value: CompareTab.fourFrames, label: "4コマ"),
            ],
            selection: $tab
        )
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendItem(swingA, color: Theme.swingA)
            Spacer(minLength: 0)
            legendItem(swingB, color: Theme.swingB)
        }
    }

    private func legendItem(_ swing: Swing, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 12, height: 12)
            Text(legendTitle(swing))
                .font(AppFont.jp(15, .bold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private var notes: some View {
        ForEach(pairing.notes, id: \.self) { note in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(theme.textSecondary)
                Text(note)
                    .font(AppFont.jp(13))
                    .foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(theme.card))
            .padding(.horizontal, isLandscape ? 0 : 16)
        }
    }

    @ViewBuilder
    private var videoStage: some View {
        switch videoLayout {
        case .overlay:
            OverlayStage(
                playback: playback,
                opacity: overlayOpacity,
                offset: overlayOffset,
                tagText: stageTag
            )
        case .sideBySide:
            SideBySideStage(playback: playback, titleA: legendTitle(swingA), titleB: legendTitle(swingB))
                .padding(.horizontal, isLandscape ? 0 : 16)
        }
    }

    private var videoControls: some View {
        VStack(spacing: 4) {
            SeekBar(
                progress: (playback.time - playback.range.lowerBound) / (playback.range.upperBound - playback.range.lowerBound),
                marks: playback.checkpointMarks
            ) { fraction in
                let range = playback.range
                playback.seek(to: range.lowerBound + fraction * (range.upperBound - range.lowerBound))
            }
            PlaybackButtons(playback: playback, size: isLandscape ? 48 : Sizes.controlButton) {
                showExportDialog = true
            }
            if videoLayout == .overlay {
                sliderRow("不透明度") {
                    ThinSlider(
                        value: $overlayOpacity,
                        label: "不透明度",
                        valueText: "\(Int(overlayOpacity * 100))%"
                    )
                }
                .padding(.top, 8)
                sliderRow("位置（左右）") {
                    ThinSlider(
                        value: $overlayOffset,
                        range: -1...1,
                        label: "位置（左右）",
                        valueText: overlayOffset == 0 ? "中央" : String(format: "%+.0f", overlayOffset * 100)
                    )
                }
            }
        }
    }

    private func sliderRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 16) {
            Text(title)
                .font(AppFont.jp(13, .medium))
                .foregroundStyle(theme.textSecondary)
                .frame(width: 84, alignment: .leading)
            content()
        }
        .frame(height: 44)
    }

    private var metricsTable: some View {
        MetricsTable(titleA: shortTitle(swingA), titleB: shortTitle(swingB), a: swingA.metrics, b: swingB.metrics)
    }

    // MARK: 文言

    private var baseSwing: Swing? { pins.first?.swing }

    private func roleName(_ swing: Swing) -> String? {
        if swing == baseSwing { return "基準スイング" }
        if swing == latestSwings.first { return "最新球" }
        return nil
    }

    /// 例 "#20 最新球"、日をまたぐ時は "9/20 #15 基準スイング"
    private func legendTitle(_ swing: Swing) -> String {
        let date = pairing.sameDay ? "" : "\(DateText.short(swing.capturedAt)) "
        return "\(date)\(swing.displayNumber) \(roleName(swing) ?? swing.club.label)"
    }

    /// 数値表の見出し。例 "最新" "基準" "#19"
    private func shortTitle(_ swing: Swing) -> String {
        if swing == baseSwing { return "基準" }
        if swing == latestSwings.first { return "最新" }
        return swing.displayNumber
    }

    /// 重ね合わせの右上。例 "後方・7I"
    private var stageTag: String {
        pairing.sameClub ? "\(swingA.angle.label)・\(swingA.club.label)" : swingA.angle.label
    }

    private func export(_ url: URL) async {
        do {
            try await PhotoExporter.saveVideo(at: url)
            exportMessage = "カメラロールに保存しました"
        } catch {
            exportMessage = "保存できませんでした。写真へのアクセスを設定で確認してください"
        }
    }
}

#Preview("重ね合わせ（最新球 vs 基準スイング）") {
    CompareView(swingA: PreviewData.latest, swingB: PreviewData.base)
        .previewEnvironment()
}

#Preview("4コマ（クラブ違い）") {
    CompareView(swingA: PreviewData.latest, swingB: PreviewData.driverSwing)
        .previewEnvironment()
}

#Preview("横並び（横向き）", traits: .landscapeLeft) {
    CompareView(swingA: PreviewData.latest, swingB: PreviewData.base)
        .previewEnvironment()
}

#Preview("重ね合わせ・屋外表示") {
    CompareView(swingA: PreviewData.latest, swingB: PreviewData.base)
        .previewEnvironment(outdoor: true)
}
