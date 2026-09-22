import SwiftUI
import UIKit

/// 緑の主要ボタン（56〜60pt）
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(AppFont.jp(18, .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity, minHeight: Sizes.primaryButtonHeight)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(Theme.accent))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)
                .contentShape(Rectangle())
        }
    }
}

/// 面の色の副ボタン（56〜60pt）
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(AppFont.jp(17, .bold))
                .foregroundStyle(theme.textPrimary)
                .frame(maxWidth: .infinity, minHeight: Sizes.primaryButtonHeight)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.raised))
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
                .contentShape(Rectangle())
        }
    }
}

struct CircleIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = Sizes.iconButton
    let action: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: Sizes.iconButton, height: Sizes.iconButton, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("戻る")
    }
}

/// 写真・動画の上に載せる小さなラベル
struct PhotoChip: View {
    let text: String
    var fill: Color = Theme.photoChip
    var foreground: Color = .white

    var body: some View {
        Text(text)
            .font(AppFont.jp(12, .bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: Radius.small, style: .continuous).fill(fill))
    }
}

/// 「基準」の緑ラベル
struct BaseBadge: View {
    var body: some View {
        PhotoChip(text: "基準", fill: Theme.accent, foreground: Theme.onAccent)
    }
}

/// 状態表示のカプセル（撮影画面上部）
struct StatusPill<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(text)
                .font(AppFont.jp(14, .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .background(Capsule().fill(Theme.photoChipStrong))
    }
}

/// モックの「重ね合わせ / 4コマ」「後方 / 斜め後方 / 横・正面」のような切り替え
struct SegmentedPill<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var height: CGFloat = 44

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let selected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(AppFont.jp(15, selected ? .bold : .medium))
                        .foregroundStyle(selected ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.medium - 2, style: .continuous)
                                .fill(selected ? theme.strokeStrong.opacity(theme.isOutdoor ? 0.35 : 0.6) : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .frame(height: height)
        .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(theme.card))
    }
}

/// 設定画面などのカード
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
    }
}

/// 動画・静止画がない時の代わり。モックの写真は使わず、グラデーションと SF Symbols で描く
struct ClipPlaceholder: View {
    var seed: Int = 0
    var tint: Color?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: tint.map { [$0.opacity(0.35), $0.opacity(0.12)] }
                        ?? [Color(hex: 0x6E8A9A), Color(hex: 0x3F5B48), Color(hex: 0x2C4A33)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Image(systemName: "figure.golf")
                    .resizable()
                    .scaledToFit()
                    .frame(height: geo.size.height * 0.62)
                    .foregroundStyle(tint ?? Color.white.opacity(0.85))
                    .offset(
                        x: CGFloat(seed % 5 - 2) * geo.size.width * 0.012,
                        y: geo.size.height * 0.08
                    )
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .accessibilityHidden(true)
    }
}

/// スイングのサムネイル（アドレス時点の静止画）
struct SwingThumbnail: View {
    let swing: Swing
    @State private var image: UIImage?

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    ClipPlaceholder(seed: swing.number)
                }
            }
            .clipped()
            .task(id: swing.clipFileName) {
                guard let url = swing.clipURL else { return }
                image = await FrameImageLoader.shared.image(url: url, at: swing.addressTime ?? 0.5, maxPixel: 400)
            }
    }
}
