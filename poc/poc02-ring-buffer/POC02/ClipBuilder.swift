import AVFoundation
import QuartzCore

/// 確定済みのチャンクをつないで1球ぶんのクリップを作る。
///
/// 連結の方式:
/// AVMutableComposition に各チャンクの必要な範囲を並べ、AVAssetExportSession のパススルー
/// （AVAssetExportPresetPassthrough）で .mov に書き出す。
/// - 再エンコードしないので速い。「インパクトから数秒以内に確定」を満たすには、8秒ぶんの 1080p/60fps を
///   エンコードし直す AVAssetReader/Writer 方式より有利
/// - 画質が落ちない
/// - どのチャンクもキーフレームで始まるので、チャンクの継ぎ目はそのままつなげる
/// - クリップの先頭（インパクトの5秒前）はチャンクの途中に落ちるが、.mov の編集リストで表されるので、
///   直前のキーフレームからのデータを含めたうえで再生は指定した時刻から始まる
/// 継ぎ目のシークやコマ送りが本当に破綻しないかは、このPOCで実機再生して確かめる。
enum ClipBuilder {
    struct Part: Sendable {
        let url: URL
        /// チャンクの先頭と終わり（セッションの秒。ファイル内の0秒が startT）
        let startT: Double
        let endT: Double
    }

    struct Plan: Sendable {
        let parts: [Part]
        /// 切り出す範囲（セッションの秒）
        let startT: Double
        let endT: Double
        let output: URL
    }

    struct Result: Sendable {
        /// 書き出したクリップの実際の長さ（ファイルから読み直した値）
        var durationSeconds: Double = 0
        var bytes: Int64 = 0
        var exportMs: Double = 0
        var error: String?
    }

    static func build(_ plan: Plan) async -> Result {
        let began = CACurrentMediaTime()
        var result = Result()
        do {
            let composition = try await compose(plan)
            try? FileManager.default.removeItem(at: plan.output)
            guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw ClipError.exportUnavailable
            }
            try await export.export(to: plan.output, as: .mov)
            result.exportMs = (CACurrentMediaTime() - began) * 1000

            let duration = try await AVURLAsset(url: plan.output).load(.duration)
            result.durationSeconds = duration.seconds
            let attributes = try FileManager.default.attributesOfItem(atPath: plan.output.path)
            result.bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            result.exportMs = (CACurrentMediaTime() - began) * 1000
            result.error = error.localizedDescription
            try? FileManager.default.removeItem(at: plan.output)
        }
        return result
    }

    private static func compose(_ plan: Plan) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ClipError.compositionFailed }
        var audioTrack: AVMutableCompositionTrack?
        var cursor = CMTime.zero

        for (i, part) in plan.parts.enumerated() {
            let asset = AVURLAsset(url: part.url)
            guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                throw ClipError.missingVideo(part.url.lastPathComponent)
            }
            if i == 0 {
                videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
            }
            let wanted = CMTimeRange(
                start: time(max(plan.startT, part.startT) - part.startT),
                end: time(min(plan.endT, part.endT) - part.startT))
            let range = CMTimeRangeGetIntersection(wanted, otherRange: try await sourceVideo.load(.timeRange))
            guard CMTimeCompare(range.duration, .zero) > 0 else { continue }
            try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)

            // 音声は映像と同じ範囲に揃える。チャンクの音声が映像より短い場合は、その部分だけ無音になる
            if let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first {
                let audioRange = CMTimeRangeGetIntersection(range, otherRange: try await sourceAudio.load(.timeRange))
                if CMTimeCompare(audioRange.duration, .zero) > 0 {
                    if audioTrack == nil {
                        audioTrack = composition.addMutableTrack(
                            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                    }
                    let at = CMTimeAdd(cursor, CMTimeSubtract(audioRange.start, range.start))
                    try audioTrack?.insertTimeRange(audioRange, of: sourceAudio, at: at)
                }
            }
            cursor = CMTimeAdd(cursor, range.duration)
        }
        guard CMTimeCompare(cursor, .zero) > 0 else { throw ClipError.empty }
        return composition
    }

    private static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 60_000)
    }
}

enum ClipError: LocalizedError {
    case exportUnavailable
    case compositionFailed
    case missingVideo(String)
    case empty

    var errorDescription: String? {
        switch self {
        case .exportUnavailable: "パススルーの書き出しを作れません"
        case .compositionFailed: "コンポジションを作れません"
        case .missingVideo(let name): "チャンクに映像がありません: \(name)"
        case .empty: "切り出す範囲にチャンクがありません"
        }
    }
}
