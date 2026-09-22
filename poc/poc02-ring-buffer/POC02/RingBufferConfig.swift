import Foundation

/// POC-02 の暫定値。定数はすべてここに集める。
/// 計測開始時に config.json（ringBuffer 側）としてセッションフォルダに保存し、tools/summarize.py が同じキー名で読む。
/// 実打の判定の値は POC-01 の DetectionConfig をそのまま使う（config.json の detection 側）。
/// DetectionConfig の frameRate / videoBitRate はこのアプリでは使わない。撮影はこちらの値で行う。
struct RingBufferConfig: Codable {
    // MARK: 撮影

    var frameRate: Int = 60
    var videoBitRate: Int = 8_000_000
    /// キーフレームの最大間隔（フレーム数）。チャンクの先頭は必ずキーフレームになるので、連結のためではなく
    /// 切り出したクリップのシークとコマ送りのため。60fps で 0.5秒
    var maxKeyFrameIntervalFrames: Int = 30

    // MARK: リングバッファ

    /// 1チャンクの長さ（秒）。実際の境界は、この長さを超えた最初の映像フレームになる
    var chunkSeconds: Double = 1.0
    /// ディスクに残す確定済みチャンクの数。これより古いものは、切り出し待ちのクリップが使っていなければ消す。
    /// 前5秒＋後3秒＝8秒に、実打判定の遅れとチャンク境界の端数ぶんの余裕2つを足した値
    var retainedChunks: Int = 10

    // MARK: クリップ

    /// インパクト時刻の前後に切り出す秒数
    var clipBeforeSeconds: Double = 5
    var clipAfterSeconds: Double = 3

    // MARK: 試験用トリガ

    /// 一定間隔トリガの間隔（秒）。4秒なら前5秒＋後3秒のクリップが隣と4秒ずつ重なる（docs の連続打撃の例）
    var intervalTriggerSeconds: Double = 4

    // MARK: 記録

    /// チャンクを閉じる時、境界より後ろの音声が届くのをこれ以上は待たない（映像の時刻で測る）
    var audioCloseGraceSeconds: Double = 0.5
    /// disk.csv に書く間隔
    var diskLogIntervalSeconds: Double = 1
    /// true なら計測終了時に残っているチャンクを消さずに残す（連結前の素材を確かめたい時）
    var keepChunksAtEnd: Bool = false

    static let `default` = RingBufferConfig()
}

/// config.json に書く中身
struct SessionConfig: Codable {
    var ringBuffer: RingBufferConfig
    var detection: DetectionConfig
}
