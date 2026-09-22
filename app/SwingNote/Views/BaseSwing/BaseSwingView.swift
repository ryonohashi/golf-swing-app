import SwiftData
import SwiftUI

/// 06 基準スイング。アプリが良いと判定した球ではなく、ユーザーが比較の基準として選んだ1球。v1 は1本だけ。
struct BaseSwingView: View {
    @Environment(\.theme) private var theme
    @Environment(Router.self) private var router

    @Query private var pins: [BaseSwingPin]
    @Query(SwingQueries.latestSwing) private var latestSwings: [Swing]

    private var pin: BaseSwingPin? { pins.first }
    private var base: Swing? { pin?.swing }
    private var latest: Swing? { latestSwings.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            BackButton()
            VStack(alignment: .leading, spacing: 8) {
                Text("基準スイング")
                    .font(AppFont.jp(26, .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("あなたが比較の基準として選んだ1球です。\n最新球はいつでもこの球と1タップで比べられます。")
                    .font(AppFont.jp(13))
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let base, let pin {
                baseCard(base, pinnedAt: pin.pinnedAt)
            } else {
                emptyCard
            }

            Spacer(minLength: 0)

            VStack(spacing: 12) {
                if let base, let latest, latest != base {
                    Button("最新球と比べる") {
                        router.open(.compare(latest, base))
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                Button(base == nil ? "スイング一覧から選ぶ" : "スイング一覧から選び直す") {
                    router.backToList()
                }
                .buttonStyle(SecondaryButtonStyle())
                Text("基準は1本だけ保持します")
                    .font(AppFont.jp(12))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func baseCard(_ swing: Swing, pinnedAt: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SwingThumbnail(swing: swing)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 200, maxHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                        .strokeBorder(Theme.swingB, lineWidth: 2)
                )
                .overlay(alignment: .topLeading) {
                    BaseBadge().padding(12)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text("\(swing.displayNumber) ・ \(swing.club.label) ・ \(swing.angle.label)")
                    .font(AppFont.jp(18, .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("\(DateText.full(pinnedAt)) に選択")
                    .font(AppFont.jp(12))
                    .foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
        .accessibilityElement(children: .combine)
    }

    private var emptyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "pin")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(theme.textSecondary)
            Text("まだ基準スイングがありません")
                .font(AppFont.jp(17, .bold))
                .foregroundStyle(theme.textPrimary)
            Text("スイング一覧で1球を選び、「基準スイングにする」を押してください。")
                .font(AppFont.jp(13))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
    }
}

#Preview("基準スイング") {
    BaseSwingView()
        .previewEnvironment()
}

#Preview("基準スイング・屋外表示") {
    BaseSwingView()
        .previewEnvironment(outdoor: true)
}

#Preview("基準スイング・未設定") {
    BaseSwingView()
        .previewEnvironment(empty: true)
}
