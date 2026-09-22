import AVFoundation

struct AudioBlock {
    /// ブロック先頭の時刻（キャプチャセッションの時計、秒）
    let t: Double
    let peakDb: Double
    let rmsDb: Double
    let highPassPeakDb: Double
}

func decibels(_ value: Double) -> Double {
    20 * log10(max(value, 1e-9))
}

/// RBJ cookbook の2次フィルタ。tools/replay.py では使わない（フィルタ後の値をログから読む）
struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    static func highPass(cutoff: Double, sampleRate: Double, q: Double = 0.7071) -> Biquad {
        let w0 = 2 * Double.pi * cutoff / sampleRate
        let cosW0 = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        var filter = Biquad()
        filter.b0 = (1 + cosW0) / 2 / a0
        filter.b1 = -(1 + cosW0) / a0
        filter.b2 = (1 + cosW0) / 2 / a0
        filter.a1 = -2 * cosW0 / a0
        filter.a2 = (1 - alpha) / a0
        return filter
    }

    mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// キャプチャした音声を一定長のブロックに切り、ピークとRMSを出す。1ch目だけを見る
final class AudioBlockMeter {
    private let blockSeconds: Double
    private let cutoffHz: Double
    private(set) var sampleRate: Double = 0
    private var blockSize = 0
    private var filter = Biquad()
    private var pending: [Float] = []
    private var pendingStart: Double = 0

    init(blockSeconds: Double, cutoffHz: Double) {
        self.blockSeconds = blockSeconds
        self.cutoffHz = cutoffHz
    }

    func process(_ sampleBuffer: CMSampleBuffer) -> [AudioBlock] {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee
        else { return [] }

        if asbd.mSampleRate != sampleRate {
            sampleRate = asbd.mSampleRate
            blockSize = max(1, Int((sampleRate * blockSeconds).rounded()))
            filter = Biquad.highPass(cutoff: cutoffHz, sampleRate: sampleRate)
            pending.removeAll()
        }

        let samples = firstChannel(of: sampleBuffer, asbd: asbd)
        guard !samples.isEmpty else { return [] }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let expected = pendingStart + Double(pending.count) / sampleRate
        if pending.isEmpty || abs(pts - expected) > blockSeconds {
            // 途切れたら端数を捨てて時刻を取り直す
            pending.removeAll()
            pendingStart = pts
        }
        pending.append(contentsOf: samples)

        var blocks: [AudioBlock] = []
        var offset = 0
        while pending.count - offset >= blockSize {
            var peak = 0.0
            var sumSquares = 0.0
            var highPassPeak = 0.0
            for i in offset..<(offset + blockSize) {
                let x = Double(pending[i])
                peak = max(peak, abs(x))
                sumSquares += x * x
                highPassPeak = max(highPassPeak, abs(filter.process(x)))
            }
            blocks.append(AudioBlock(
                t: pendingStart + Double(offset) / sampleRate,
                peakDb: decibels(peak),
                rmsDb: decibels((sumSquares / Double(blockSize)).squareRoot()),
                highPassPeakDb: decibels(highPassPeak)
            ))
            offset += blockSize
        }
        pending.removeFirst(offset)
        pendingStart += Double(offset) / sampleRate
        return blocks
    }

    private func firstChannel(of sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [Float] {
        // 2回の呼び出しで flags を揃える（必要なサイズが flags で変わりうるため）
        let flags = UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment)
        var sizeNeeded = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: flags, blockBufferOut: nil)
        guard sizeNeeded > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: list, bufferListSize: sizeNeeded,
            blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
            flags: flags, blockBufferOut: &blockBuffer)
        guard status == noErr else { return [] }

        return withExtendedLifetime(blockBuffer) {
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            guard let first = buffers.first, let data = first.mData else { return [] }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
            let isNonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            let stride = isNonInterleaved ? 1 : max(1, Int(asbd.mChannelsPerFrame))
            var out = [Float](repeating: 0, count: frames)
            if isFloat && asbd.mBitsPerChannel == 32 {
                let p = data.assumingMemoryBound(to: Float.self)
                for i in 0..<frames { out[i] = p[i * stride] }
            } else if !isFloat && asbd.mBitsPerChannel == 16 {
                let p = data.assumingMemoryBound(to: Int16.self)
                for i in 0..<frames { out[i] = Float(p[i * stride]) / 32768 }
            } else {
                return []
            }
            return out
        }
    }
}
