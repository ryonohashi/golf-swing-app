import Foundation

/// POC-01 の暫定値。定数はすべてここに集める。
/// 計測開始時に config.json としてセッションフォルダに保存し、tools/replay.py が同じキー名で読む。
struct DetectionConfig: Codable {
    // MARK: 記録時に固定（ログの形が変わるため、再解析では変えられない）

    var frameRate: Int = 60
    var videoBitRate: Int = 8_000_000
    /// 音のログと判定の時間分解能
    var audioBlockSeconds: Double = 0.01
    /// 風などの低域を落とすハイパスのカットオフ。フィルタ前後の両方をログに残す
    var highPassCutoffHz: Double = 1000
    /// 動き量を記録するセルの分割数（縦向き画面を cols × rows に分ける）
    var motionGridCols: Int = 6
    var motionGridRows: Int = 8
    /// 輝度を間引いて見る間隔（ピクセル）
    var motionSampleStep: Int = 8
    /// 前フレームからこれ以上輝度が変わった点を「動いた」と数える
    var motionPixelDiffThreshold: Int = 25

    // MARK: 再解析で変えられる

    /// true ならハイパス後のピークで音を判定する
    var useHighPass: Bool = true
    /// 環境音の床からこれ以上大きい音をインパクト音の候補にする
    var audioRelativeThresholdDb: Double = 20
    /// これより小さい音は床との差に関係なく無視する
    var audioAbsoluteMinDb: Double = -40
    /// 環境音の床の追従の遅さ
    var audioFloorTauSeconds: Double = 2.0
    /// 1ショットで鳴る2つ目のピーク（クラブとマット）を潰す幅
    var audioDebounceSeconds: Double = 0.5
    /// 動き検出の範囲。x0, y0, x1, y1（縦向き画面の正規化座標、左上原点）。中心がこの中に入るセルを使う
    var roi: [Double] = [0.15, 0.05, 0.85, 0.95]
    /// ROI内の「動いた点」の割合がこれを超えたら動きの区間を開始する
    var motionOnThreshold: Double = 0.08
    /// これを下回った状態が motionOffHoldSeconds 続いたら区間を終える
    var motionOffThreshold: Double = 0.03
    var motionOffHoldSeconds: Double = 0.25
    /// スイング候補とみなす動きの区間の長さと強さ
    var minSwingSeconds: Double = 0.4
    var maxSwingSeconds: Double = 6.0
    var minSwingPeak: Double = 0.15
    /// スイング候補 [start - before, end + after] の中にインパクト音があれば実打とする
    var windowBeforeStartSeconds: Double = 0.2
    var windowAfterEndSeconds: Double = 0.3

    static let `default` = DetectionConfig()

    /// ROI に中心が入るセルの番号（行優先）
    func roiCells() -> [Int] {
        var cells: [Int] = []
        for row in 0..<motionGridRows {
            for col in 0..<motionGridCols {
                let cx = (Double(col) + 0.5) / Double(motionGridCols)
                let cy = (Double(row) + 0.5) / Double(motionGridRows)
                if roi[0] <= cx && cx <= roi[2] && roi[1] <= cy && cy <= roi[3] {
                    cells.append(row * motionGridCols + col)
                }
            }
        }
        return cells
    }
}
