import AVFoundation

/// 映像と音声を書くための設定。最初の映像フレームを見てから決める
struct WriterTemplate {
    let videoSettings: [String: Any]
    let audioSettings: [String: Any]?
}

/// 1チャンク＝1つの AVAssetWriter。
///
/// チャンクの切り方:
/// 1本の AVAssetWriter の途中でファイルを切り替えることはできないので、チャンクごとに別の AVAssetWriter を使う。
/// 新しい AVAssetWriter の最初のフレームは必ずキーフレーム（IDR）になるため、どのチャンクも単独で頭から再生でき、
/// 連結の継ぎ目で前のチャンクを参照することがない。
///
/// フレームを落とさないための工夫:
/// AVAssetWriter.startWriting() はエンコーダの準備を含むので数十msかかることがある。境界でこれを呼ぶと
/// キャプチャのキューが止まり、後続のフレームが詰まる。そこで次のチャンク用の AVAssetWriter を
/// 別キューで先に startWriting() まで済ませて待機させておき（待機中のライタ）、境界では
/// startSession(atSourceTime:) と append だけを行う。境界は映像フレームの時刻そのもので、
/// 前のチャンクは endSession(atSourceTime: 境界) で閉じる。映像は境界のフレームの直前までが前、
/// 境界のフレームからが次に入るので、1フレームも重ならず、1フレームも抜けない。
///
/// 音声は境界をまたぐバッファ（1つ約21ms）があるので、またぐものは両方のチャンクに渡す。
/// 前のチャンクでは endSession で後ろが、次のチャンクでは startSession より前が切り捨てられる。
final class ChunkWriter {
    let index: Int
    let url: URL
    let writer: AVAssetWriter
    let videoInput: AVAssetWriterInput
    let audioInput: AVAssetWriterInput?
    private(set) var startPTS = CMTime.invalid
    /// 次のチャンクの先頭フレームの時刻。閉じる時に決まる
    var endPTS = CMTime.invalid
    private(set) var videoFrames = 0

    /// startWriting() まで済ませる。時間がかかるのでキャプチャのキュー以外で呼ぶのが望ましい
    init(index: Int, url: URL, template: WriterTemplate) throws {
        self.index = index
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: template.videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw ChunkError.cannotAddInput }
        writer.add(videoInput)

        var audio: AVAssetWriterInput?
        if let settings = template.audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audio = input
            }
        }
        audioInput = audio

        guard writer.startWriting() else { throw writer.error ?? ChunkError.cannotStart }
    }

    var isStarted: Bool { startPTS.isValid }

    /// チャンクの先頭を決める。ファイル内の0秒がこの時刻になる
    func begin(at pts: CMTime) {
        writer.startSession(atSourceTime: pts)
        startPTS = pts
    }

    /// 書けなかった（エンコーダが追いつかない）時は false
    func appendVideo(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) else { return false }
        videoFrames += 1
        return true
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let audioInput else { return true }
        return audioInput.isReadyForMoreMediaData && audioInput.append(sampleBuffer)
    }

    /// endPTS を決めてから呼ぶ。completion は任意のスレッドで呼ばれる
    func finish(completion: @escaping () -> Void) {
        // 失敗済みのライタに endSession / finishWriting を呼ぶと例外になるので、そのまま結果を返す
        guard writer.status == .writing else {
            completion()
            return
        }
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        writer.endSession(atSourceTime: endPTS)
        writer.finishWriting(completionHandler: completion)
    }

    /// 使わなかった待機中のライタを捨てる
    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}

enum ChunkError: LocalizedError {
    case cannotAddInput
    case cannotStart

    var errorDescription: String? {
        switch self {
        case .cannotAddInput: "チャンクに映像の入力を追加できません"
        case .cannotStart: "チャンクの書き出しを開始できません"
        }
    }
}
