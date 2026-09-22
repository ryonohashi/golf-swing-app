import SwiftData
import SwiftUI

/// 03 スイング一覧。最新球と基準スイングの比較を先頭に置き、それ以外の2球はユーザーがここで選ぶ。
/// アプリが比べる2球を提案することはしない。
struct SwingListView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(Router.self) private var router

    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Query(SwingQueries.latestSwing) private var latestSwings: [Swing]
    @Query private var pins: [BaseSwingPin]

    /// [0] が A（青）、[1] が B（オレンジ）
    @State private var selection: [Swing] = []
    @State private var showLimitHint = false

    private var latest: Swing? { latestSwings.first }
    private var baseSwing: Swing? { pins.first?.swing }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let latest {
                    LatestVersusBaseCard(latest: latest, base: baseSwing) {
                        if let baseSwing { router.open(.compare(latest, baseSwing)) }
                    }
                }
                if sessions.isEmpty {
                    emptyState
                }
                ForEach(Array(sessions.enumerated()), id: \.element.persistentModelID) { index, session in
                    sessionSection(session, isFirst: index == 0)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            selectionBar
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: ヘッダー

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                BackButton()
                Spacer()
                CircleIconButton(systemName: "pin", label: "基準スイング") {
                    router.open(.baseSwing)
                }
                CircleIconButton(systemName: "gearshape", label: "設定") {
                    router.open(.settings)
                }
            }
            if let session = sessions.first {
                Text(session.title)
                    .font(AppFont.jp(26, .bold))
                    .foregroundStyle(theme.textPrimary)
                Text(session.summaryText)
                    .font(AppFont.jp(13))
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text("スイング一覧")
                    .font(AppFont.jp(26, .bold))
                    .foregroundStyle(theme.textPrimary)
            }
        }
        .padding(.top, 4)
    }

    private var emptyState: some View {
        Text("まだスイングがありません。\n端末を置いて打つと、1球ずつここに並びます。")
            .font(AppFont.jp(15))
            .foregroundStyle(theme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 24)
    }

    // MARK: セッション

    @ViewBuilder
    private func sessionSection(_ session: Session, isFirst: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if !isFirst {
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title)
                        .font(AppFont.jp(20, .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text(session.summaryText)
                        .font(AppFont.jp(12))
                        .foregroundStyle(theme.textSecondary)
                }
                .padding(.top, 12)
            }
            ForEach(session.clubGroups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(group.club.label) ・ \(group.swings.count)球")
                        .font(AppFont.jp(13, .medium))
                        .foregroundStyle(theme.textSecondary)
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(group.swings) { swing in
                            SwingCell(
                                swing: swing,
                                selectionIndex: selection.firstIndex(of: swing),
                                isBase: swing == baseSwing
                            )
                            .onTapGesture { toggle(swing) }
                        }
                    }
                }
            }
        }
    }

    private func toggle(_ swing: Swing) {
        if let index = selection.firstIndex(of: swing) {
            selection.remove(at: index)
            showLimitHint = false
        } else if selection.count < 2 {
            selection.append(swing)
        } else {
            // 3球目は勝手に入れ替えない。外してから選び直してもらう
            showLimitHint = true
        }
    }

    // MARK: 下部の選択バー

    @ViewBuilder
    private var selectionBar: some View {
        if selection.isEmpty {
            Text("比較する2球をタップして選んでください")
                .font(AppFont.jp(13))
                .foregroundStyle(theme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(theme.background)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    Text("\(selection.count)球を選択中")
                        .font(AppFont.jp(13))
                        .foregroundStyle(theme.textSecondary)
                    ForEach(Array(selection.enumerated()), id: \.offset) { index, swing in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(index == 0 ? Theme.swingA : Theme.swingB)
                                .frame(width: 12, height: 12)
                            Text(swing.displayNumber)
                                .font(AppFont.number(14, .bold))
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    Spacer()
                }
                if showLimitHint {
                    Text("選べるのは2球までです。外すにはもう一度タップしてください")
                        .font(AppFont.jp(12))
                        .foregroundStyle(theme.textSecondary)
                }
                if selection.count == 2 {
                    Button("この2球を比較") {
                        router.open(.compare(selection[0], selection[1]))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                } else if let only = selection.first {
                    Text("もう1球選ぶと比較できます")
                        .font(AppFont.jp(12))
                        .foregroundStyle(theme.textSecondary)
                    if only != baseSwing {
                        Button("\(only.displayNumber)を基準スイングにする") {
                            SwingLibrary.pinAsBase(only, context: context)
                            selection.removeAll()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(
                theme.background
                    .overlay(alignment: .top) { theme.separator.frame(height: 1) }
                    .ignoresSafeArea(edges: .bottom)
            )
        }
    }
}

/// 「最新球 vs 基準スイング」の1タップ比較
struct LatestVersusBaseCard: View {
    let latest: Swing
    let base: Swing?
    let onCompare: () -> Void

    @Environment(\.theme) private var theme

    private var canCompare: Bool { base != nil && base != latest }

    private var title: String {
        guard let base else { return "基準スイングが未設定です" }
        return base == latest ? "最新球が基準スイングです" : "基準スイングと比べる"
    }

    private var subtitle: String {
        base == nil
            ? "一覧で1球を選んで「基準スイングにする」を押してください"
            : "最新球 \(latest.displayNumber) ・ \(latest.club.label)"
    }

    var body: some View {
        Button(action: onCompare) {
            HStack(spacing: 14) {
                SwingThumbnail(swing: latest)
                    .frame(width: 48, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Text(subtitle)
                        .font(AppFont.jp(12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                    Text(title)
                        .font(AppFont.jp(18, .bold))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                if canCompare {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                        .frame(width: 68, height: 56)
                        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(Theme.accent))
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canCompare)
        .accessibilityLabel(canCompare ? "最新球 \(latest.displayNumber) を基準スイングと比べる" : title)
    }
}

/// 一覧の1マス
struct SwingCell: View {
    let swing: Swing
    /// 0 なら A、1 なら B、nil なら未選択
    let selectionIndex: Int?
    let isBase: Bool

    private var selectionColor: Color? {
        switch selectionIndex {
        case 0: Theme.swingA
        case 1: Theme.swingB
        default: nil
        }
    }

    var body: some View {
        SwingThumbnail(swing: swing)
            .aspectRatio(0.78, contentMode: .fit)
            .overlay(alignment: .topLeading) {
                PhotoChip(text: "\(swing.number)")
                    .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                selectionMark.padding(6)
            }
            .overlay(alignment: .bottomLeading) {
                if isBase { BaseBadge().padding(6) }
            }
            .overlay(alignment: .bottomTrailing) {
                PhotoChip(text: swing.durationText)
                    .padding(6)
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay {
                if let selectionColor {
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(selectionColor, lineWidth: 3)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var selectionMark: some View {
        if let selectionColor, let selectionIndex {
            Text(selectionIndex == 0 ? "A" : "B")
                .font(AppFont.jp(13, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(selectionColor))
        } else {
            Circle()
                .fill(Color.black.opacity(0.25))
                .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                .frame(width: 26, height: 26)
        }
    }

    private var accessibilityText: String {
        var parts = ["\(swing.displayNumber)", swing.club.label, swing.durationText]
        if isBase { parts.append("基準スイング") }
        if let selectionIndex { parts.append(selectionIndex == 0 ? "A として選択中" : "B として選択中") }
        return parts.joined(separator: "、")
    }
}

#Preview("スイング一覧") {
    SwingListView()
        .previewEnvironment()
}

#Preview("スイング一覧・屋外表示") {
    SwingListView()
        .previewEnvironment(outdoor: true)
}

#Preview("スイング一覧・データなし") {
    SwingListView()
        .previewEnvironment(empty: true)
}
