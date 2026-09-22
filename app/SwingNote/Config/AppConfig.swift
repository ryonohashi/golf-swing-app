import Foundation

/// 暫定値。CLAUDE.md の「暫定値」表と対応する。POC の結果が出たらここだけを差し替える。
struct CaptureConfig {
    /// クリップの切り出し範囲：インパクト音の前（POC-02 で確定）
    var secondsBeforeImpact: Double = 5
    /// クリップの切り出し範囲：インパクト音の後（POC-02 で確定）
    var secondsAfterImpact: Double = 3
    /// リングバッファ長（POC-02 で確定）
    var ringBufferSeconds: Double = 8
    /// チャンク長。未定（1〜2秒を想定、POC-02 で確定）
    var chunkSeconds: Double? = nil
    /// フレームレート（POC-03 で確定）
    var frameRate: Int = 60
    /// デバウンス幅。未定（0.5〜1秒を想定、POC-01 で確定）
    var debounceSeconds: Double? = nil

    var clipDuration: Double { secondsBeforeImpact + secondsAfterImpact }

    static let current = CaptureConfig()
}

/// 画面まわりの調整値。POC とは無関係だが、触る場所を1箇所にまとめる。
enum UIConfig {
    /// クリップ確定フラッシュを出しておく秒数
    static let flashSeconds: Double = 1.2
    /// 撮影待機画面を暗転させるまでの無操作秒数
    static let captureDimDelaySeconds: Double = 30
    /// スロー再生の速さ
    static let slowPlaybackRate: Float = 0.25
    /// 重ね合わせの不透明度の初期値
    static let defaultOverlayOpacity: Double = 0.5
    /// 位置（左右）スライダーを端まで動かした時のずれ（表示幅に対する割合）
    static let overlayMaxOffsetFraction: Double = 0.25
}

/// セッションの区切り方。
enum SessionRule {
    /// 同じ暦日のスイングは1つのセッションにまとめる（暫定。日付をまたぐ練習は未検討）
    static func belongsToSameSession(sessionStart: Date, date: Date) -> Bool {
        Calendar.current.isDate(sessionStart, inSameDayAs: date)
    }
}
