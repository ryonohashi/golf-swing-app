import SwiftUI
import UIKit

/// 04 重ね合わせ。B（暖色）の上に A（寒色）を半透明で重ね、A を左右に動かして位置を合わせる。
/// 輪郭線や骨格の矢印は描かない。
struct OverlayStage: View {
    let playback: ComparePlayback
    let opacity: Double
    /// -1〜1。端まで動かすと表示幅の UIConfig.overlayMaxOffsetFraction だけずれる
    let offset: Double
    let tagText: String

    var body: some View {
        GeometryReader { geo in
            ZStack {
                layer(isA: false)
                layer(isA: true)
                    .opacity(opacity)
                    .offset(x: CGFloat(offset * UIConfig.overlayMaxOffsetFraction) * geo.size.width)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .background(Color.black)
        .overlay(alignment: .topLeading) {
            if let checkpoint = playback.currentCheckpoint {
                PhotoChip(text: checkpoint.label).padding(10)
            }
        }
        .overlay(alignment: .topTrailing) {
            PhotoChip(text: tagText).padding(10)
        }
    }

    @ViewBuilder
    private func layer(isA: Bool) -> some View {
        if playback.hasVideo {
            PlayerLayerView(player: isA ? playback.playerA : playback.playerB)
        } else {
            ClipPlaceholder(
                seed: isA ? playback.a.seed : playback.b.seed,
                tint: isA ? Theme.swingA : Theme.swingB
            )
        }
    }
}

/// 横並び。端末が横向きの時、または撮影アングルが違う時の既定
struct SideBySideStage: View {
    let playback: ComparePlayback
    let titleA: String
    let titleB: String

    var body: some View {
        HStack(spacing: 8) {
            pane(isA: true)
            pane(isA: false)
        }
    }

    private func pane(isA: Bool) -> some View {
        let color = isA ? Theme.swingA : Theme.swingB
        return ZStack {
            Color.black
            if playback.hasVideo {
                PlayerLayerView(player: isA ? playback.playerA : playback.playerB)
            } else {
                ClipPlaceholder(seed: isA ? playback.a.seed : playback.b.seed)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(color, lineWidth: 2))
        .overlay(alignment: .topLeading) {
            PhotoChip(text: isA ? titleA : titleB).padding(8)
        }
        .overlay(alignment: .bottom) {
            if isA, let checkpoint = playback.currentCheckpoint {
                PhotoChip(text: checkpoint.label).padding(8)
            }
        }
    }
}

/// 05 4コマ。アドレス／トップ／インパクト／フィニッシュを静止画で左右に並べる
struct FourFrameComparison: View {
    let a: ClipInfo
    let b: ClipInfo
    let isLandscape: Bool

    var body: some View {
        if isLandscape {
            // 横向き：上段に A の4コマ、下段に B の4コマ
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    ForEach(Checkpoint.allCases) { checkpoint in
                        StillFrame(clip: a, checkpoint: checkpoint, color: Theme.swingA)
                            .overlay(alignment: .bottom) { PhotoChip(text: checkpoint.label).padding(6) }
                    }
                }
                GridRow {
                    ForEach(Checkpoint.allCases) { checkpoint in
                        StillFrame(clip: b, checkpoint: checkpoint, color: Theme.swingB)
                    }
                }
            }
        } else {
            VStack(spacing: 12) {
                ForEach(Checkpoint.allCases) { checkpoint in
                    HStack(spacing: 8) {
                        StillFrame(clip: a, checkpoint: checkpoint, color: Theme.swingA)
                        StillFrame(clip: b, checkpoint: checkpoint, color: Theme.swingB)
                    }
                    .overlay(alignment: .bottom) {
                        PhotoChip(text: checkpoint.label, fill: Theme.photoChipStrong)
                            .padding(.bottom, 12)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(checkpoint.label)
                }
            }
        }
    }
}

struct StillFrame: View {
    let clip: ClipInfo
    let checkpoint: Checkpoint
    let color: Color

    @State private var image: UIImage?

    var body: some View {
        Color.black
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ClipPlaceholder(seed: clip.seed &+ checkpoint.rawValue)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).strokeBorder(color, lineWidth: 2))
            .task(id: clip.checkpoints[checkpoint]) {
                guard let url = clip.url, let time = clip.checkpoints[checkpoint] else { return }
                image = await FrameImageLoader.shared.image(url: url, at: time, maxPixel: 800)
            }
    }
}
