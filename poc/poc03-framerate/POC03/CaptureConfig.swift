import Foundation

/// POC-03 の暫定値。定数はすべてここに集める。
/// 計測開始時に config.json としてセッションフォルダに保存し、tools/summarize.py が同じキー名で読む。
struct CaptureConfig: Codable {
    // MARK: 画面で変える

    /// 撮影開始時のフレームレート
    var frameRate: Int = 60
    /// 毎フレーム POC-01 の動き検出を回す。製品でも常時回るので、負荷を揃えるため既定でオン
    var motionMeterEnabled: Bool = true
    /// 計測中に画面を黒くし、明るさを dimBrightness まで下げる
    var dimScreen: Bool = false

    // MARK: 撮影

    var frameRateChoices: [Int] = [60, 120]
    /// 優先する解像度（センサーの向きのまま。縦向きにすると 1080x1920）
    var preferredWidth: Int = 1920
    var preferredHeight: Int = 1080
    /// 優先解像度で目的の fps が出ない時に、下げてよい解像度の下限（長辺）
    var minFallbackWidth: Int = 1280
    /// fps ごとの平均ビットレート（bps）。書き出しの途中では変えられないので、開始時の fps で決まる
    var videoBitRates: [String: Int] = ["30": 5_000_000, "60": 8_000_000, "120": 14_000_000]
    /// この間隔で動画ファイルに目次を書く。発熱でアプリが落ちても、そこまでの動画を再生できる
    var movieFragmentSeconds: Double = 10

    // MARK: 記録

    /// status.csv に1行書く間隔
    var logIntervalSeconds: Double = 10
    /// 画面暗転時の明るさ（0〜1）
    var dimBrightness: Double = 0
    /// 0 なら上限なし。超えたら自動で計測を終える
    var sessionLimitMinutes: Double = 0

    // MARK: 発熱時の fps 降格

    var autoDowngrade: Bool = true
    /// ProcessInfo.ThermalState の rawValue（0 nominal / 1 fair / 2 serious / 3 critical）。これ以上で降格する
    var downgradeThermalState: Int = 2
    /// 降格先。キーは今の fps。発熱状態が一段上がるたびに一段ずつ下げる（serious で 120→60、critical で 60→30）
    var downgradeSteps: [String: Int] = ["120": 60, "60": 30]
    /// true なら、発熱状態が restoreThermalState 以下に戻った時に開始時の fps に戻す
    var restoreAfterCooling: Bool = false
    var restoreThermalState: Int = 1

    // MARK: 動き検出（POC-01 の設定をそのまま使う）

    var motion: DetectionConfig = DetectionConfig.default

    static let `default` = CaptureConfig()

    func bitRate(for fps: Int) -> Int {
        if let rate = videoBitRates[String(fps)] { return rate }
        // 表にない fps は 60fps の値から比例で決める
        let base = videoBitRates["60"] ?? 8_000_000
        return base * fps / 60
    }
}
