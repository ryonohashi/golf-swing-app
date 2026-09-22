import SwiftUI

/// 07 設定。撮影モードは普段選ばせないので、ここだけで切り替える。
struct SettingsView: View {
    @Environment(\.theme) private var theme

    @AppStorage(SettingsKey.captureMode) private var captureModeRaw = CaptureMode.auto.rawValue
    @AppStorage(SettingsKey.outdoorDisplay) private var outdoorDisplay = false
    @AppStorage(SettingsKey.cameraAngle) private var angleRaw = CameraAngle.downTheLine.rawValue

    private let config = CaptureConfig.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                BackButton()
                Text("設定")
                    .font(AppFont.jp(26, .bold))
                    .foregroundStyle(theme.textPrimary)
                    .padding(.bottom, 8)

                sectionTitle("撮影モード")
                Card {
                    ForEach(Array(CaptureMode.allCases.enumerated()), id: \.element) { index, mode in
                        if index > 0 { divider }
                        modeRow(mode)
                    }
                }

                sectionTitle("表示")
                Card {
                    Toggle(isOn: $outdoorDisplay) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("屋外表示")
                                .font(AppFont.jp(17, .bold))
                                .foregroundStyle(theme.textPrimary)
                            Text("明るい背景で直射日光下でも読みやすく")
                                .font(AppFont.jp(12))
                                .foregroundStyle(theme.textSecondary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 64)
                }

                sectionTitle("撮影アングル")
                SegmentedPill(
                    options: CameraAngle.allCases.map { (value: $0.rawValue, label: $0.label) },
                    selection: $angleRaw,
                    height: 56
                )

                sectionTitle("クリップ")
                Card {
                    infoRow("フレームレート", "\(config.frameRate)fps")
                    divider
                    infoRow("保存範囲", "打球音の前\(seconds(config.secondsBeforeImpact))秒・後\(seconds(config.secondsAfterImpact))秒")
                }

                Text("動画はすべてこの端末の中だけに保存されます。")
                    .font(AppFont.jp(12))
                    .foregroundStyle(theme.textSecondary)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(theme.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(AppFont.jp(13, .medium))
            .foregroundStyle(theme.textSecondary)
            .padding(.top, 12)
    }

    private var divider: some View {
        theme.separator
            .frame(height: 1)
            .padding(.horizontal, 16)
    }

    private func modeRow(_ mode: CaptureMode) -> some View {
        let selected = mode.rawValue == captureModeRaw
        return Button {
            captureModeRaw = mode.rawValue
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(AppFont.jp(17, .bold))
                        .foregroundStyle(theme.textPrimary)
                    Text(mode.detail)
                        .font(AppFont.jp(12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                ZStack {
                    Circle()
                        .strokeBorder(selected ? Theme.accent : theme.strokeStrong, lineWidth: 2)
                    if selected {
                        Circle().fill(Theme.accent).padding(3)
                        Circle().fill(theme.card).padding(8)
                    }
                }
                .frame(width: 26, height: 26)
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(AppFont.jp(16, .bold))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            Text(value)
                .font(AppFont.jp(14))
                .foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 56)
        .accessibilityElement(children: .combine)
    }

    private func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

#Preview("設定") {
    SettingsView()
        .previewEnvironment()
}

#Preview("設定・屋外表示") {
    SettingsView()
        .previewEnvironment(outdoor: true)
}
