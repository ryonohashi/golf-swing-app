import Foundation

/// UserDefaults のキー。画面側は @AppStorage、サービス側は AppPreferences から同じキーを読む。
enum SettingsKey {
    static let outdoorDisplay = "settings.outdoorDisplay"
    static let captureMode = "settings.captureMode"
    static let cameraAngle = "settings.cameraAngle"
    /// ブロック単位で継承するクラブ。変更するまで以降のスイングに付く
    static let currentClub = "settings.currentClub"
}

enum AppPreferences {
    static var captureMode: CaptureMode {
        CaptureMode(rawValue: UserDefaults.standard.string(forKey: SettingsKey.captureMode) ?? "") ?? .auto
    }

    static var cameraAngle: CameraAngle {
        CameraAngle(rawValue: UserDefaults.standard.string(forKey: SettingsKey.cameraAngle) ?? "") ?? .downTheLine
    }

    static var currentClub: ClubTag {
        ClubTag(rawValue: UserDefaults.standard.string(forKey: SettingsKey.currentClub) ?? "") ?? .iron7
    }
}
