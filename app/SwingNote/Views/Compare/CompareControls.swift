import SwiftUI

/// 見た目は細く、当たり判定は 60pt のスライダー（spec-ui タップ対象）
struct ThinSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    let label: String
    let valueText: String

    @Environment(\.theme) private var theme

    private let thumb: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumb, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.stroke)
                    .frame(height: 4)
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(theme.strokeStrong.opacity(theme.isOutdoor ? 1 : 0), lineWidth: 1))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(fraction) * usable)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let x = min(max(drag.location.x - thumb / 2, 0), usable)
                    value = range.lowerBound + Double(x / usable) * (range.upperBound - range.lowerBound)
                }
            )
        }
        .frame(height: Sizes.preciseHitHeight)
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
        }
    }
}

/// 再生位置のシークバー。チェックポイントの位置に目盛りを付ける
struct SeekBar: View {
    let progress: Double
    let marks: [Double]
    let onSeek: (Double) -> Void

    @Environment(\.theme) private var theme

    private let thumb: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumb, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.stroke)
                    .frame(height: 4)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: thumb / 2 + CGFloat(progress) * usable, height: 4)
                ForEach(marks.indices, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(theme.textSecondary)
                        .frame(width: 2, height: 12)
                        .offset(x: thumb / 2 - 1 + CGFloat(marks[index]) * usable)
                }
                Circle()
                    .fill(.white)
                    .overlay(Circle().strokeBorder(theme.strokeStrong.opacity(theme.isOutdoor ? 1 : 0), lineWidth: 1))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: CGFloat(progress) * usable)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { drag in
                    let x = min(max(drag.location.x - thumb / 2, 0), usable)
                    onSeek(Double(x / usable))
                }
            )
        }
        .frame(height: Sizes.preciseHitHeight)
        .accessibilityElement()
        .accessibilityLabel("再生位置")
        .accessibilityValue("\(Int(progress * 100))%")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSeek(min(progress + 0.05, 1))
            case .decrement: onSeek(max(progress - 0.05, 0))
            @unknown default: break
            }
        }
    }
}

/// 戻る・0.25x・再生・送る・保存のボタン列
struct PlaybackButtons: View {
    let playback: ComparePlayback
    var size: CGFloat = Sizes.controlButton
    let onExport: () -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            control(systemName: "backward.frame.fill", label: "1コマ戻る") { playback.step(frames: -1) }
            Spacer(minLength: 4)
            Button {
                playback.toggleSlow()
            } label: {
                Text("0.25x")
                    .font(AppFont.number(15, .bold))
                    .foregroundStyle(playback.isSlow ? Theme.onAccent : theme.textPrimary)
                    .frame(width: size, height: size)
                    .background(Circle().fill(playback.isSlow ? Theme.accent.opacity(0.85) : theme.raised))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("0.25倍速")
            .accessibilityAddTraits(playback.isSlow ? .isSelected : [])
            Spacer(minLength: 4)
            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: size + 4, height: size + 4)
                    .background(Circle().fill(Theme.accent))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(playback.isPlaying ? "一時停止" : "再生")
            Spacer(minLength: 4)
            control(systemName: "forward.frame.fill", label: "1コマ送る") { playback.step(frames: 1) }
            Spacer(minLength: 4)
            control(systemName: "square.and.arrow.up", label: "カメラロールに保存", action: onExport)
        }
    }

    private func control(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .frame(width: size, height: size)
                .background(Circle().fill(theme.raised))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// 動きの差分の数値表。どちらが良いかの色分けはしない
struct MetricsTable: View {
    let titleA: String
    let titleB: String
    let a: BodyMotionMetrics
    let b: BodyMotionMetrics

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(titleA)
                        .font(AppFont.jp(12, .bold))
                        .foregroundStyle(Theme.swingA)
                        .gridColumnAlignment(.trailing)
                    Text(titleB)
                        .font(AppFont.jp(12, .bold))
                        .foregroundStyle(Theme.swingB)
                        .gridColumnAlignment(.trailing)
                }
                ForEach(MetricKind.allCases) { kind in
                    GridRow {
                        Text(kind.label)
                            .font(AppFont.jp(14, .medium))
                            .foregroundStyle(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text(kind.format(a[kind]))
                            .font(AppFont.number(14, .bold))
                            .foregroundStyle(theme.textPrimary)
                        Text(kind.format(b[kind]))
                            .font(AppFont.number(14, .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("2D映像から求めた身体の動きの値です。フェース角や打点は映像に映りません。")
                .font(AppFont.jp(11))
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
    }
}
