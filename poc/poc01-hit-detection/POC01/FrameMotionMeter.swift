import CoreVideo

/// 前フレームとの輝度差分で、セルごとの動き量を出す。
/// ROI をあとから変えて再解析できるよう、ROI で絞らずに全セルを返す。
final class FrameMotionMeter {
    private let cols: Int
    private let rows: Int
    private let step: Int
    private let threshold: Int
    private var previous: [UInt8] = []
    private var previousWidth = 0
    private var previousHeight = 0

    init(config: DetectionConfig) {
        cols = config.motionGridCols
        rows = config.motionGridRows
        step = config.motionSampleStep
        threshold = config.motionPixelDiffThreshold
    }

    /// 各セルで「前フレームから輝度が閾値以上変わった点」の割合（行優先、cols × rows 個）。
    /// 1フレーム目は比べる相手がないので nil
    func process(_ pixelBuffer: CVPixelBuffer) -> [Double]? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else { return nil }

        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let gridWidth = width / step
        let gridHeight = height / step
        guard gridWidth > 0, gridHeight > 0 else { return nil }

        let luma = base.assumingMemoryBound(to: UInt8.self)
        var current = [UInt8](repeating: 0, count: gridWidth * gridHeight)
        for gy in 0..<gridHeight {
            let row = luma + gy * step * bytesPerRow
            for gx in 0..<gridWidth {
                current[gy * gridWidth + gx] = row[gx * step]
            }
        }

        defer {
            previous = current
            previousWidth = gridWidth
            previousHeight = gridHeight
        }
        guard previousWidth == gridWidth, previousHeight == gridHeight else { return nil }

        var changed = [Int](repeating: 0, count: cols * rows)
        var total = [Int](repeating: 0, count: cols * rows)
        for gy in 0..<gridHeight {
            let cellRow = gy * rows / gridHeight
            for gx in 0..<gridWidth {
                let cell = cellRow * cols + gx * cols / gridWidth
                let i = gy * gridWidth + gx
                total[cell] += 1
                if abs(Int(current[i]) - Int(previous[i])) >= threshold {
                    changed[cell] += 1
                }
            }
        }
        return zip(changed, total).map { $1 > 0 ? Double($0) / Double($1) : 0 }
    }
}
