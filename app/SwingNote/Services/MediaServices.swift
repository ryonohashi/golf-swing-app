import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Photos
import UIKit

/// クリップから静止画を取り出す。サムネイルと4コマで使う。
actor FrameImageLoader {
    static let shared = FrameImageLoader()

    private let cache = NSCache<NSString, UIImage>()

    func image(url: URL, at seconds: Double, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.lastPathComponent)|\(seconds)|\(maxPixel)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        guard let result = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)) else {
            return nil
        }
        let image = UIImage(cgImage: result.image)
        cache.setObject(image, forKey: key)
        return image
    }
}

/// 重ね合わせのティント。輝度に色を掛けるカラーマトリクス1つで、一方を寒色、他方を暖色にする。
/// 人物のセグメンテーション（輪郭線）は使わない。
struct Tint: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat

    /// Theme.swingA と同じ色
    static let cold = Tint(red: 0x3F / 255, green: 0xA7 / 255, blue: 1)
    /// Theme.swingB と同じ色
    static let warm = Tint(red: 1, green: 0x8A / 255, blue: 0x3D / 255)

    func apply(to image: CIImage) -> CIImage {
        // 出力の各チャンネル = 輝度 × 色 × gain + 少しの持ち上げ
        let gain: CGFloat = 1.25
        let luma = (r: 0.299 * gain, g: 0.587 * gain, b: 0.114 * gain)
        let filter = CIFilter.colorMatrix()
        filter.inputImage = image
        filter.rVector = CIVector(x: luma.r * red, y: luma.g * red, z: luma.b * red, w: 0)
        filter.gVector = CIVector(x: luma.r * green, y: luma.g * green, z: luma.b * green, w: 0)
        filter.bVector = CIVector(x: luma.r * blue, y: luma.g * blue, z: luma.b * blue, w: 0)
        filter.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        filter.biasVector = CIVector(x: 0.06 * red, y: 0.06 * green, z: 0.06 * blue, w: 0)
        return filter.outputImage ?? image
    }
}

enum TintedPlayerItem {
    /// tint が nil なら元の色のまま
    static func make(url: URL, tint: Tint?) async -> AVPlayerItem {
        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        guard let tint else { return item }
        let composition = try? await AVVideoComposition.videoComposition(
            with: asset,
            applyingCIFiltersWithHandler: { request in
                let output = tint.apply(to: request.sourceImage.clampedToExtent())
                    .cropped(to: request.sourceImage.extent)
                request.finish(with: output, context: nil)
            }
        )
        item.videoComposition = composition
        return item
    }
}

/// カメラロールへの書き出し（v1 のエクスポート）。追加のみの権限で足りる。
enum PhotoExporter {
    enum ExportError: Error {
        case notAuthorized
    }

    static func saveVideo(at url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw ExportError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
