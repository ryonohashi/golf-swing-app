import SwiftData
import SwiftUI
import UIKit

/// 01 撮影待機。端末を2m先に置いて使う。撮影は自動なので録画ボタンは置かない（手動モードの時だけ出す）。
struct CaptureView: View {
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var context
    @Environment(CaptureCoordinator.self) private var coordinator
    @Environment(Router.self) private var router

    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Query(SwingQueries.latestSwing) private var latestSwings: [Swing]

    @AppStorage(SettingsKey.captureMode) private var captureModeRaw = CaptureMode.auto.rawValue
    @AppStorage(SettingsKey.currentClub) private var clubRaw = ClubTag.iron7.rawValue

    @State private var showClubPicker = false
    @State private var lastTouch = Date.now
    @State private var isDimmed = false

    private var mode: CaptureMode { CaptureMode(rawValue: captureModeRaw) ?? .auto }
    private var club: ClubTag { ClubTag(rawValue: clubRaw) ?? .iron7 }
    private var status: CaptureStatus { coordinator.service.status }

    private var todayCount: Int {
        guard let session = sessions.first,
              SessionRule.belongsToSameSession(sessionStart: session.startedAt, date: .now)
        else { return 0 }
        return session.swings.count
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            preview
            bottomBar
        }
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if isDimmed {
                dimOverlay
            }
        }
        .overlay {
            if let flash = coordinator.flash {
                FlashView(count: flash.count)
                    .transition(.opacity)
                    .task(id: flash.id) {
                        try? await Task.sleep(for: .seconds(UIConfig.flashSeconds))
                        withAnimation(.easeOut(duration: 0.25)) { coordinator.dismissFlash() }
                    }
            }
        }
        .simultaneousGesture(TapGesture().onEnded { wake() })
        .onAppear {
            OrientationLock.portraitOnly()
            UIApplication.shared.isIdleTimerDisabled = true
            coordinator.start(context: context)
            wake()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            coordinator.stop()
        }
        .task {
            // 撮影待機中は画面を暗転する（spec-capture 発熱・電池）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if !isDimmed, Date.now.timeIntervalSince(lastTouch) > UIConfig.captureDimDelaySeconds {
                    withAnimation(.easeInOut(duration: 0.6)) { isDimmed = true }
                }
            }
        }
        .sheet(isPresented: $showClubPicker) {
            ClubPickerSheet(clubRaw: $clubRaw)
                .environment(\.theme, theme)
        }
    }

    private func wake() {
        lastTouch = .now
        if isDimmed {
            withAnimation(.easeInOut(duration: 0.3)) { isDimmed = false }
        }
    }

    // MARK: 上部

    private var topBar: some View {
        HStack(spacing: 8) {
            topChip("\(coordinator.service.frameRate)fps")
            topChip(mode.label)
            Spacer()
            statusPill
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func topChip(_ text: String) -> some View {
        Text(text)
            .font(AppFont.jp(14, .bold))
            .monospacedDigit()
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(theme.card))
    }

    private var statusPill: some View {
        StatusPill(text: status.label) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
        }
        #if DEBUG
        // 開発用：長押しで実打を1回起こす（モック撮影の時だけ）
        .onLongPressGesture(minimumDuration: 1) {
            (coordinator.service as? MockCaptureService)?.simulateHit()
        }
        #endif
        .accessibilityLabel("撮影の状態：\(status.label)")
    }

    private var statusColor: Color {
        switch status {
        case .waiting, .manualReady: Theme.accent
        case .swingCandidate, .saving: .white
        case .manualRecording: .red
        case .powerSaving, .stopped, .unavailable: Color(hex: 0x9AA59F)
        }
    }

    // MARK: プレビュー

    private var preview: some View {
        ZStack(alignment: .bottom) {
            CameraPreviewPlaceholder()
            CompositionGuide()
                .padding(.vertical, 12)
            VStack(spacing: 16) {
                if mode == .manual {
                    manualRecordButton
                }
                Text("枠に全身が入るように置いてください")
                    .font(AppFont.jp(14, .bold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 3)
            }
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    /// 手動モードだけの録画ボタン。自動モードでは出さない
    private var manualRecordButton: some View {
        let recording = status == .manualRecording
        return Button {
            coordinator.service.toggleManualRecording()
        } label: {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4)
                RoundedRectangle(cornerRadius: recording ? 6 : 30, style: .continuous)
                    .fill(.red)
                    .padding(recording ? 22 : 8)
            }
            .frame(width: 76, height: 76)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "録画を止めて保存" : "録画を始める")
    }

    // MARK: 下部

    private var bottomBar: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                Text("今日の本数")
                    .font(AppFont.jp(13, .medium))
                    .foregroundStyle(theme.textSecondary)
                Text("\(todayCount)")
                    .font(AppFont.number(56, .bold))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .contentTransition(.numericText())
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            if let latest = latestSwings.first {
                Button {
                    router.open(.list)
                } label: {
                    VStack(spacing: 4) {
                        SwingThumbnail(swing: latest)
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
                        Text("最新球")
                            .font(AppFont.jp(11, .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("最新球 \(latest.displayNumber)。スイング一覧を開く")
            } else {
                // まだ1球もない時も一覧・設定へ行けるようにする
                Button {
                    router.open(.list)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 56, height: 56)
                            .background(RoundedRectangle(cornerRadius: Radius.medium, style: .continuous).fill(theme.card))
                        Text("一覧")
                            .font(AppFont.jp(11, .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("スイング一覧を開く")
            }

            Button {
                showClubPicker = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("クラブ")
                            .font(AppFont.jp(12, .medium))
                            .foregroundStyle(theme.textSecondary)
                        Text(club.label)
                            .font(AppFont.number(22, .bold))
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer(minLength: 4)
                    Text("変更")
                        .font(AppFont.jp(14, .bold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 16)
                .frame(width: 132, height: Sizes.primaryButtonHeight)
                .background(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).fill(theme.card))
                .overlay(RoundedRectangle(cornerRadius: Radius.large, style: .continuous).strokeBorder(theme.separator, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("クラブ \(club.label)。変更する")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var dimOverlay: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()
            VStack(spacing: 12) {
                Text("\(todayCount)")
                    .font(AppFont.number(40, .bold))
                    .foregroundStyle(.white.opacity(0.35))
                Circle()
                    .fill(statusColor.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { wake() }
        .accessibilityLabel("画面を暗くしています。タップで戻ります")
    }
}

/// カメラ映像の代わり。本物のプレビューは撮影の実装（POC-02）と一緒に差し替える
struct CameraPreviewPlaceholder: View {
    var body: some View {
        LinearGradient(
            colors: [Color(hex: 0x2A3A44), Color(hex: 0x1D2B22), Color(hex: 0x16241A)],
            startPoint: .top,
            endPoint: .bottom
        )
        .overlay(alignment: .center) {
            Image(systemName: "video")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.15))
                .offset(y: -40)
        }
        .accessibilityHidden(true)
    }
}

/// 構図ガイド。固定の人型シルエット（アドレス姿勢、後方から）を点線で重ねる
struct CompositionGuide: View {
    var body: some View {
        AddressSilhouette()
            .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round, dash: [9, 7]))
            .aspectRatio(393.0 / 600.0, contentMode: .fit)
            .accessibilityHidden(true)
    }
}

/// モック01の点線をなぞった形。座標は 393×600 の枠に対する割合
struct AddressSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        var path = Path()

        // 頭
        path.addEllipse(in: CGRect(
            x: rect.minX + 0.405 * rect.width,
            y: rect.minY + 0.125 * rect.height,
            width: 0.145 * rect.width,
            height: 0.105 * rect.height
        ))

        // 背中から脚、つま先、すね、腿、腕、胸へ一周
        path.move(to: p(0.43, 0.245))
        path.addQuadCurve(to: p(0.22, 0.46), control: p(0.25, 0.28))
        path.addLine(to: p(0.19, 0.84))
        path.addLine(to: p(0.38, 0.875))
        path.addLine(to: p(0.33, 0.675))
        path.addLine(to: p(0.42, 0.53))
        path.addLine(to: p(0.47, 0.53))
        path.addLine(to: p(0.55, 0.33))
        path.addQuadCurve(to: p(0.53, 0.245), control: p(0.575, 0.265))
        path.closeSubpath()
        return path
    }
}

#Preview("撮影待機") {
    CaptureView()
        .previewEnvironment()
}

#Preview("撮影待機・屋外表示") {
    CaptureView()
        .previewEnvironment(outdoor: true)
}

#Preview("撮影待機・データなし") {
    CaptureView()
        .previewEnvironment(empty: true)
}
