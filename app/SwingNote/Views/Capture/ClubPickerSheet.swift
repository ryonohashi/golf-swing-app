import SwiftUI

/// クラブの変更。一度選べば、変えるまで以降のスイングに付く（ブロック単位の継承）
struct ClubPickerSheet: View {
    @Binding var clubRaw: String

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("クラブ")
                    .font(AppFont.jp(22, .bold))
                    .foregroundStyle(theme.textPrimary)
                Text("次に打つ球から、このクラブが付きます")
                    .font(AppFont.jp(13))
                    .foregroundStyle(theme.textSecondary)
            }
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ClubTag.allCases) { club in
                    let selected = club.rawValue == clubRaw
                    Button {
                        clubRaw = club.rawValue
                        dismiss()
                    } label: {
                        Text(club.label)
                            .font(AppFont.number(20, .bold))
                            .foregroundStyle(selected ? Theme.onAccent : theme.textPrimary)
                            .frame(maxWidth: .infinity, minHeight: Sizes.primaryButtonHeight)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.medium, style: .continuous)
                                    .fill(selected ? Theme.accent : theme.raised)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .presentationDetents([.medium])
        .presentationBackground(theme.background)
    }
}

#Preview("クラブ変更") {
    @Previewable @State var club = ClubTag.iron7.rawValue
    ClubPickerSheet(clubRaw: $club)
        .background(Theme.dark.background)
        .themed(outdoor: false)
}
