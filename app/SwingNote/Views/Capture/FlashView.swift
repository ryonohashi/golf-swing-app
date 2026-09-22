import SwiftUI

/// 02 クリップ確定フラッシュ。2m先・直射日光下で読めるよう、文字ではなく色と数字だけで伝える。
struct FlashView: View {
    let count: Int

    var body: some View {
        ZStack {
            Theme.accent.ignoresSafeArea()
            VStack(spacing: 48) {
                Text("\(count)")
                    .font(AppFont.number(240, .heavy))
                    .tracking(-10)
                    .foregroundStyle(Theme.onAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
                    .padding(.horizontal, 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 60, height: 60)
                    .background(Circle().fill(Color.black.opacity(0.1)))
            }
            .offset(y: -20)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count)球目を保存しました")
    }
}

#Preview("クリップ確定") {
    FlashView(count: 13)
}

#Preview("クリップ確定・3桁") {
    FlashView(count: 128)
}
