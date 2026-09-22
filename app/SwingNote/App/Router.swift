import Observation
import SwiftUI
import UIKit

enum Route: Hashable {
    case list
    /// a は青（寒色）側、b はオレンジ（暖色）側
    case compare(Swing, Swing)
    case baseSwing
    case settings
}

@MainActor
@Observable
final class Router {
    var path: [Route] = []

    func open(_ route: Route) {
        path.append(route)
    }

    /// スイング一覧まで戻る。一覧が積まれていなければ一覧を開く
    func backToList() {
        if let index = path.lastIndex(of: .list) {
            path.removeSubrange((index + 1)...)
        } else {
            path.append(.list)
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    /// 撮影は縦固定、比較画面だけ横向きを許可する
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}

@MainActor
enum OrientationLock {
    static func allowLandscape() {
        update(.allButUpsideDown, force: nil)
    }

    static func portraitOnly() {
        update(.portrait, force: .portrait)
    }

    private static func update(_ mask: UIInterfaceOrientationMask, force: UIInterfaceOrientationMask?) {
        AppDelegate.orientationMask = mask
        guard let scene = activeScene else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        if let force {
            scene.requestGeometryUpdate(UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: force)) { _ in }
        }
    }

    fileprivate static var activeScene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// 屋外表示の時は画面の明るさを最大にし、戻したら元の明るさに戻す。
@MainActor
enum ScreenBrightness {
    private static var saved: CGFloat?

    static func apply(outdoor: Bool) {
        guard let screen = OrientationLock.activeScene?.screen else { return }
        if outdoor {
            if saved == nil { saved = screen.brightness }
            screen.brightness = 1
        } else if let saved {
            screen.brightness = saved
            self.saved = nil
        }
    }
}
