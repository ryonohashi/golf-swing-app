import SwiftData
import SwiftUI

@main
struct SwingNoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var coordinator = CaptureCoordinator.live()
    @State private var router = Router()

    private let container: ModelContainer = {
        // CloudKit 同期はしない（v1 は完全ローカル）
        let configuration = ModelConfiguration(cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: Schema(SwingNoteSchema.models), configurations: [configuration])
        } catch {
            fatalError("SwiftData の初期化に失敗しました: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(coordinator)
                .environment(router)
        }
        .modelContainer(container)
    }
}

struct RootView: View {
    @Environment(Router.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(SettingsKey.outdoorDisplay) private var outdoorDisplay = false

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
            CaptureView()
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .list:
                        SwingListView()
                    case .compare(let a, let b):
                        CompareView(swingA: a, swingB: b)
                    case .baseSwing:
                        BaseSwingView()
                    case .settings:
                        SettingsView()
                    }
                }
        }
        .themed(outdoor: outdoorDisplay)
        .onChange(of: outdoorDisplay, initial: true) { _, outdoor in
            ScreenBrightness.apply(outdoor: outdoor)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { ScreenBrightness.apply(outdoor: outdoorDisplay) }
        }
    }
}

extension View {
    /// 屋外表示のオン・オフに合わせて配色を切り替える
    func themed(outdoor: Bool) -> some View {
        environment(\.theme, outdoor ? .outdoor : .dark)
            .preferredColorScheme(outdoor ? .light : .dark)
            .tint(Theme.accent)
    }
}
