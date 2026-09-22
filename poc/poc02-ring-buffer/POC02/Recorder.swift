import AVFoundation
import UIKit

struct SessionMeta: Codable {
    var device: String
    var systemVersion: String
    var videoFormat: String
    var durationSeconds: Double
    var videoFrames: Int
    var droppedFrames: Int
    var audioDroppedBuffers: Int
    var chunksWritten: Int
    var chunksFailed: Int
    var chunksDeleted: Int
    /// 境界で待機中のライタが用意できておらず、その場で作った回数
    var standbyMisses: Int
    var maxChunkFiles: Int
    var maxChunkBytes: Int64
    /// トリガの種類（hit / manual / interval）ごとの回数
    var triggers: [String: Int]
    var clipsSaved: Int
    var clipsFailed: Int
    var clipBytesTotal: Int64
    /// 終了時のセッションフォルダ全体の容量
    var sessionBytesAtEnd: Int64
    var stopReason: String?
}

enum ClipSource: String {
    /// POC-01 の判定（動作＋インパクト音）
    case hit
    /// 画面のボタン。押した時刻をインパクト時刻とみなす
    case manual
    /// 一定間隔。連続打撃とクリップの重なりを試すため
    case interval
}

/// クリップ1本の切り出し依頼
private struct ClipRequest {
    let number: Int
    let source: ClipSource
    let impactT: Double
    let triggerT: Double
    let startT: Double
    let endT: Double
    var bufferedT = 0.0

    func needs(_ chunk: ChunkInfo) -> Bool {
        chunk.endT > startT && chunk.startT < endT
    }
}

/// ディスク上の確定済みチャンク
private struct ChunkInfo {
    let index: Int
    let url: URL
    let startT: Double
    let endT: Double
    let frames: Int
    let bytes: Int64
}

private struct PendingAudio {
    let buffer: CMSampleBuffer
    let pts: CMTime
    let end: CMTime
}

private struct Stats {
    var videoFrames = 0
    var droppedFrames = 0
    var audioDropped = 0
    var chunksWritten = 0
    var chunksFailed = 0
    var chunksDeleted = 0
    var standbyMisses = 0
    var maxChunkFiles = 0
    var maxChunkBytes: Int64 = 0
    var triggers: [String: Int] = [:]
    var clipsSaved = 0
    var clipsFailed = 0
    var clipBytes: Int64 = 0
}

/// カメラとマイクを回し、短いチャンクを循環保存しながら、トリガのたびに前後の秒数を1本のクリップにする。
///
/// 流れ（すべて queue 上）:
/// 映像フレーム → 境界ならチャンクを切り替え → 書き込み → 音声を振り分け → 閉じたチャンクを確定
///   → トリガ（実打判定／ボタン／一定間隔）でクリップの依頼を積む
///   → インパクト＋後の秒数までのチャンクが確定したら連結を始める
///   → 依頼中と連結中のクリップが使うチャンクは消さず、それ以外の古いチャンクを消す
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRunning = false
    @Published private(set) var clipCount = 0
    @Published private(set) var failedClipCount = 0
    /// 切り出し待ちと連結中のクリップ数
    @Published private(set) var pendingCount = 0
    /// 直近のクリップの、インパクトから保存完了までの秒数
    @Published private(set) var lastLatency: Double?
    @Published private(set) var chunkFiles = 0
    @Published private(set) var diskBytes: Int64 = 0
    @Published private(set) var intervalEnabled = false
    @Published private(set) var statusText = "準備中"

    let session = AVCaptureSession()
    let config = RingBufferConfig.default
    let detectionConfig = DetectionConfig.default

    private let queue = DispatchQueue(label: "poc02.capture")
    /// 待機中のライタの準備（startWriting がキャプチャを止めないように）
    private let prepareQueue = DispatchQueue(label: "poc02.prepare")
    /// ディスク使用量の集計
    private let ioQueue = DispatchQueue(label: "poc02.io", qos: .utility)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioMeter: AudioBlockMeter
    private let motionMeter: FrameMotionMeter
    private let frameDuration: CMTime
    private let systemVersion = UIDevice.current.systemVersion
    private var videoFormat = ""
    private var thermalObserver: NSObjectProtocol?

    // ここから下は queue 上でのみ触る
    private var recording = false
    private var stopping = false
    private var stopReason: String?
    /// 計測ごとに増やす。前の計測の非同期処理の結果を捨てるため
    private var generation = 0
    private var log: SessionLog?
    private var detector: HitDetector?
    private var clock: CMClock = CMClockGetHostTimeClock()
    /// t = 0 にあたるキャプチャ時刻（計測開始後の最初の映像フレーム）
    private var origin: CMTime?
    private var template: WriterTemplate?
    /// いま映像を書いているチャンク
    private var active: ChunkWriter?
    /// 次の境界で使う、startWriting 済みのチャンク
    private var standby: ChunkWriter?
    private var standbyPreparing = false
    /// 境界を過ぎたが、境界より前の音声を待っているチャンク
    private var closing: [ChunkWriter] = []
    /// finishWriting の完了を待っているチャンクの数
    private var finishingChunks = 0
    private var nextChunkIndex = 0
    /// ディスク上の確定済みチャンク（先頭時刻の順）
    private var chunks: [ChunkInfo] = []
    /// ここまでの時刻はチャンクとして確定している
    private var bufferedUntilT = -Double.infinity
    /// まだ振り分けていない音声（境界が決まるまで待たせる）
    private var pendingAudio: [PendingAudio] = []
    private var audioRoutedEnd = CMTime.negativeInfinity
    private var pendingClips: [ClipRequest] = []
    private var buildingClips: [Int: ClipRequest] = [:]
    private var nextClipNumber = 1
    private var intervalOn = false
    private var nextIntervalT = 0.0
    private var lastT = 0.0
    private var lastVideoPTS = CMTime.invalid
    private var lastDiskT = -Double.infinity
    private var diskSampling = false
    private var stats = Stats()

    override init() {
        let detection = DetectionConfig.default
        audioMeter = AudioBlockMeter(blockSeconds: detection.audioBlockSeconds, cutoffHz: detection.highPassCutoffHz)
        motionMeter = FrameMotionMeter(config: detection)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(RingBufferConfig.default.frameRate))
        super.init()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.logThermalState() }
        }
    }

    deinit {
        if let thermalObserver { NotificationCenter.default.removeObserver(thermalObserver) }
    }

    // MARK: - 準備

    @MainActor
    func prepare() async {
        guard !isReady else { return }
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video, audio else {
            statusText = "カメラとマイクの許可が必要です"
            return
        }
        queue.async { [self] in
            do {
                try configureSession()
                session.startRunning()
                DispatchQueue.main.async {
                    self.isReady = true
                    self.statusText = "待機中 \(self.videoFormat)"
                }
            } catch {
                DispatchQueue.main.async { self.statusText = "カメラを開けません: \(error.localizedDescription)" }
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let microphone = AVCaptureDevice.default(for: .audio)
        else { throw RecorderError.deviceUnavailable }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
            throw RecorderError.deviceUnavailable
        }
        session.addInput(cameraInput)
        session.addInput(microphoneInput)
        try selectFormat(of: camera)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        // リングバッファはフレームを落とさず残したい
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
            throw RecorderError.deviceUnavailable
        }
        session.addOutput(videoOutput)
        session.addOutput(audioOutput)

        // 縦向きの画像として受け取る。チャンクもクリップも縦長の画素で書かれる（回転のメタデータに頼らない）
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    private func selectFormat(of device: AVCaptureDevice) throws {
        let fps = Double(config.frameRate)
        let candidates = device.formats.filter { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == 1920 && size.height == 1080
                && format.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= fps }
        }
        let fullRange = candidates.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
        guard let format = fullRange ?? candidates.first else { throw RecorderError.formatUnavailable }

        try device.lockForConfiguration()
        device.activeFormat = format
        device.activeVideoMinFrameDuration = frameDuration
        device.activeVideoMaxFrameDuration = frameDuration
        device.unlockForConfiguration()
        videoFormat = "1080x1920@\(config.frameRate)"
    }

    // MARK: - 画面からの操作

    @MainActor
    func start() {
        guard isReady, !isRunning else { return }
        isRunning = true
        clipCount = 0
        failedClipCount = 0
        pendingCount = 0
        lastLatency = nil
        chunkFiles = 0
        diskBytes = 0
        statusText = "計測中"
        UIApplication.shared.isIdleTimerDisabled = true
        let intervalOn = intervalEnabled

        queue.async { [self] in
            do {
                log = try SessionLog(config: SessionConfig(ringBuffer: config, detection: detectionConfig))
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    UIApplication.shared.isIdleTimerDisabled = false
                    self.statusText = "ログを作れません: \(error.localizedDescription)"
                }
                return
            }
            detector = HitDetector(config: detectionConfig)
            clock = session.synchronizationClock ?? CMClockGetHostTimeClock()
            origin = nil
            template = nil
            active = nil
            standby = nil
            standbyPreparing = false
            closing = []
            finishingChunks = 0
            nextChunkIndex = 0
            chunks = []
            bufferedUntilT = -.infinity
            pendingAudio = []
            audioRoutedEnd = .negativeInfinity
            pendingClips = []
            buildingClips = [:]
            nextClipNumber = 1
            self.intervalOn = intervalOn
            nextIntervalT = config.intervalTriggerSeconds
            lastT = 0
            lastVideoPTS = .invalid
            lastDiskT = -.infinity
            stats = Stats()
            stopReason = nil
            stopping = false
            recording = true
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        statusText = "保存中"
        queue.async { [self] in beginStop(reason: nil) }
    }

    /// 押した瞬間をインパクト時刻とみなす
    @MainActor
    func manualTrigger() {
        let now = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())
        queue.async { [self] in
            guard let origin else { return }
            trigger(.manual, impactT: CMTimeSubtract(now, origin).seconds)
        }
    }

    @MainActor
    func setIntervalEnabled(_ on: Bool) {
        intervalEnabled = on
        queue.async { [self] in
            intervalOn = on
            nextIntervalT = lastT + config.intervalTriggerSeconds
            log?.event(t: lastT, kind: on ? "interval_on" : "interval_off", config.intervalTriggerSeconds)
        }
    }

    // MARK: - 映像（queue 上）

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard recording, let log, let detector,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        if origin == nil {
            do {
                try startFirstChunk(with: pixelBuffer, at: pts)
            } catch {
                abortSession("チャンクを作れません \(error.localizedDescription)")
                return
            }
            logThermalState()
        }
        guard let origin else { return }
        let t = CMTimeSubtract(pts, origin).seconds
        lastT = t
        lastVideoPTS = pts
        stats.videoFrames += 1

        // 境界: チャンクの長さを超えた最初のフレーム（半フレームぶんの揺れは許す）
        if let current = active,
           CMTimeSubtract(pts, current.startPTS).seconds >= config.chunkSeconds - 0.5 / Double(config.frameRate) {
            do {
                try rollChunk(at: pts)
            } catch {
                abortSession("次のチャンクを作れません \(error.localizedDescription)")
                return
            }
        }
        guard let active else { return }
        if !active.appendVideo(sampleBuffer) {
            stats.droppedFrames += 1
            log.event(t: t, kind: "dropped_frame", 1)
        }
        if active.writer.status == .failed {
            abortSession("チャンクの書き出しに失敗 \(active.writer.error?.localizedDescription ?? "")")
            return
        }
        flushAudio(upTo: pts)
        finishClosingChunks(videoPTS: pts, force: false)

        if intervalOn, t >= nextIntervalT {
            nextIntervalT += config.intervalTriggerSeconds
            trigger(.interval, impactT: t)
        }

        if let cells = motionMeter.process(pixelBuffer) {
            handle(detector.addMotion(t: t, cellRatios: cells))
        }
        sampleDiskIfNeeded(t: t)
    }

    private func startFirstChunk(with pixelBuffer: CVPixelBuffer, at pts: CMTime) throws {
        template = WriterTemplate(
            videoSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
                AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: config.videoBitRate,
                    AVVideoExpectedSourceFrameRateKey: config.frameRate,
                    AVVideoMaxKeyFrameIntervalKey: config.maxKeyFrameIntervalFrames,
                ],
            ],
            audioSettings: audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov))
        // 最初の1つだけはその場で作る
        let first = try makeChunkWriter()
        first.begin(at: pts)
        active = first
        origin = pts
        requestStandby()
    }

    private func makeChunkWriter() throws -> ChunkWriter {
        guard let log, let template else { throw ChunkError.cannotStart }
        let index = nextChunkIndex
        nextChunkIndex += 1
        return try ChunkWriter(index: index, url: log.chunkURL(index: index), template: template)
    }

    /// 次のチャンクのライタを別キューで startWriting まで進めておく
    private func requestStandby() {
        guard recording, standby == nil, !standbyPreparing, let log, let template else { return }
        standbyPreparing = true
        let index = nextChunkIndex
        nextChunkIndex += 1
        let url = log.chunkURL(index: index)
        let generation = self.generation
        prepareQueue.async { [self] in
            let result = Result { try ChunkWriter(index: index, url: url, template: template) }
            queue.async { [self] in
                standbyPreparing = false
                switch result {
                case .success(let writer):
                    if recording, generation == self.generation, standby == nil {
                        standby = writer
                    } else {
                        writer.cancel()
                    }
                case .failure(let error):
                    // 次の境界でその場で作る。そこでも失敗すれば計測を止める
                    if generation == self.generation {
                        self.log?.event(t: lastT, kind: "error", note: "待機中のライタを作れません \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// pts のフレームから次のチャンクにする
    private func rollChunk(at pts: CMTime) throws {
        guard let old = active else { return }
        // 先に次を用意する。作れなければ old はそのまま active に残り、終了処理で閉じられる
        let next: ChunkWriter
        if let standby {
            next = standby
            self.standby = nil
        } else {
            let started = CACurrentMediaTime()
            next = try makeChunkWriter()
            stats.standbyMisses += 1
            log?.event(t: lastT, kind: "standby_miss", Double(next.index), (CACurrentMediaTime() - started) * 1000)
        }
        old.endPTS = pts
        closing.append(old)
        next.begin(at: pts)
        active = next
        requestStandby()
    }

    // MARK: - 音声（queue 上）

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        let blocks = audioMeter.process(sampleBuffer)
        guard recording, let detector, let origin else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        pendingAudio.append(PendingAudio(buffer: sampleBuffer, pts: pts, end: Recorder.audioEnd(of: sampleBuffer, pts: pts)))
        // 映像が止まった時に溜まり続けないように
        if pendingAudio.count > 500 {
            pendingAudio.removeFirst()
            stats.audioDropped += 1
        }

        let originSeconds = origin.seconds
        for block in blocks {
            handle(detector.addAudio(t: block.t - originSeconds, peakDb: block.peakDb, highPassPeakDb: block.highPassPeakDb))
        }
    }

    /// 音声は届いた時点では境界がまだ決まっていないことがある。映像がその時刻まで進んでから、
    /// 時刻で重なるチャンクに渡す（境界をまたぐバッファは前後両方に渡す）
    private func flushAudio(upTo limit: CMTime) {
        while let audio = pendingAudio.first, CMTimeCompare(audio.end, limit) <= 0 {
            pendingAudio.removeFirst()
            var delivered = true
            for chunk in closing where CMTimeCompare(audio.pts, chunk.endPTS) < 0 && CMTimeCompare(audio.end, chunk.startPTS) > 0 {
                delivered = chunk.appendAudio(audio.buffer) && delivered
            }
            if let active, CMTimeCompare(audio.end, active.startPTS) > 0 {
                delivered = active.appendAudio(audio.buffer) && delivered
            }
            if !delivered {
                stats.audioDropped += 1
                log?.event(t: lastT, kind: "audio_dropped", CMTimeSubtract(audio.pts, origin ?? .zero).seconds)
            }
            audioRoutedEnd = audio.end
        }
    }

    /// 境界より前の音声を渡し終えたチャンクを閉じる
    private func finishClosingChunks(videoPTS: CMTime, force: Bool) {
        let grace = CMTime(seconds: config.audioCloseGraceSeconds, preferredTimescale: 600)
        var stillOpen: [ChunkWriter] = []
        for chunk in closing {
            let audioDone = chunk.audioInput == nil || CMTimeCompare(audioRoutedEnd, chunk.endPTS) >= 0
            let timedOut = CMTimeCompare(CMTimeSubtract(videoPTS, chunk.endPTS), grace) >= 0
            if force || audioDone || timedOut {
                finishChunk(chunk)
            } else {
                stillOpen.append(chunk)
            }
        }
        closing = stillOpen
    }

    private func finishChunk(_ chunk: ChunkWriter) {
        guard let origin else { return }
        finishingChunks += 1
        let startT = CMTimeSubtract(chunk.startPTS, origin).seconds
        let endT = CMTimeSubtract(chunk.endPTS, origin).seconds
        let requested = CACurrentMediaTime()
        chunk.finish { [self] in
            let finishMs = (CACurrentMediaTime() - requested) * 1000
            queue.async { [self] in chunkFinished(chunk, startT: startT, endT: endT, finishMs: finishMs) }
        }
    }

    private func chunkFinished(_ chunk: ChunkWriter, startT: Double, endT: Double, finishMs: Double) {
        finishingChunks -= 1
        guard let log else { return }
        let now = nowT()
        if chunk.writer.status == .completed {
            let info = ChunkInfo(
                index: chunk.index, url: chunk.url, startT: startT, endT: endT,
                frames: chunk.videoFrames, bytes: Recorder.fileSize(chunk.url))
            chunks.append(info)
            chunks.sort { $0.startT < $1.startT }
            stats.chunksWritten += 1
            log.chunk(t: now, event: "finalized", index: info.index, startT: startT, endT: endT,
                      frames: info.frames, bytes: info.bytes, finishMs: finishMs)
        } else {
            stats.chunksFailed += 1
            log.chunk(t: now, event: "failed", index: chunk.index, startT: startT, endT: endT,
                      frames: chunk.videoFrames, bytes: 0, finishMs: finishMs,
                      note: chunk.writer.error?.localizedDescription ?? "status \(chunk.writer.status.rawValue)")
            try? FileManager.default.removeItem(at: chunk.url)
        }
        // 失敗したチャンクの時間も「過ぎた」ことには変わりないので進める。使うクリップには抜け（gaps）として残る
        bufferedUntilT = max(bufferedUntilT, endT)
        buildReadyClips()
        pruneChunks()
        publishStats()
        completeStopIfDone()
    }

    // MARK: - クリップ（queue 上）

    private func trigger(_ source: ClipSource, impactT: Double) {
        guard recording, let log else { return }
        let request = ClipRequest(
            number: nextClipNumber, source: source, impactT: impactT, triggerT: nowT(),
            startT: impactT - config.clipBeforeSeconds, endT: impactT + config.clipAfterSeconds)
        nextClipNumber += 1
        pendingClips.append(request)
        stats.triggers[source.rawValue, default: 0] += 1
        log.event(t: request.triggerT, kind: "trigger_\(source.rawValue)", Double(request.number), impactT)
        buildReadyClips()
        publishStats()
    }

    /// 後ろの秒数ぶんまでチャンクが確定したクリップの連結を始める。
    /// 重なるクリップ（連続打撃）もそれぞれ独立に作る（docs の案A）
    private func buildReadyClips() {
        // 終了処理ですべてのチャンクを閉じ終えたら、足りなくても今あるぶんで作る
        let finalFlush = stopping && active == nil && closing.isEmpty && finishingChunks == 0
        let canBuild = { (clip: ClipRequest) in clip.endT <= self.bufferedUntilT || finalFlush }
        let ready = pendingClips.filter(canBuild)
        pendingClips.removeAll(where: canBuild)
        for var clip in ready {
            clip.bufferedT = nowT()
            startBuild(clip)
        }
    }

    private func startBuild(_ clip: ClipRequest) {
        guard let log else { return }
        let parts = chunks.filter { clip.needs($0) }
        buildingClips[clip.number] = clip
        guard let first = parts.first, let last = parts.last else {
            // 他の連結と同じく後で記録する（ここで記録すると、終了処理が残りのクリップを待たずに進むため）
            queue.async { [self] in
                buildingClips.removeValue(forKey: clip.number)
                recordClip(clip, parts: [], result: ClipBuilder.Result(error: "切り出す範囲のチャンクがディスクにありません"))
            }
            return
        }
        let plan = ClipBuilder.Plan(
            parts: parts.map { ClipBuilder.Part(url: $0.url, startT: $0.startT, endT: $0.endT) },
            startT: max(clip.startT, first.startT), endT: min(clip.endT, last.endT),
            output: log.clipURL(number: clip.number))
        let generation = self.generation
        Task.detached { [self] in
            let result = await ClipBuilder.build(plan)
            queue.async { [self] in
                guard generation == self.generation else { return }
                buildingClips.removeValue(forKey: clip.number)
                recordClip(clip, parts: parts, result: result)
            }
        }
    }

    private func recordClip(_ clip: ClipRequest, parts: [ChunkInfo], result: ClipBuilder.Result) {
        guard let log else { return }
        let doneT = nowT()
        let halfFrame = 0.5 / Double(config.frameRate)
        let gaps = zip(parts, parts.dropFirst()).filter { $1.startT - $0.endT > halfFrame }.count
        let ok = result.error == nil
        log.clip(ClipRow(
            number: clip.number, source: clip.source.rawValue, status: ok ? "ok" : "failed",
            impactT: clip.impactT, triggerT: clip.triggerT, bufferedT: clip.bufferedT, doneT: doneT,
            exportMs: result.exportMs, requestedStart: clip.startT, requestedEnd: clip.endT,
            coveredStart: parts.first.map { max(clip.startT, $0.startT) },
            coveredEnd: parts.last.map { min(clip.endT, $0.endT) },
            actualSeconds: result.durationSeconds, chunks: parts.count, gaps: gaps, bytes: result.bytes,
            error: result.error))

        let latency = doneT - clip.impactT
        if ok {
            stats.clipsSaved += 1
            stats.clipBytes += result.bytes
        } else {
            stats.clipsFailed += 1
            log.event(t: doneT, kind: "error", Double(clip.number), note: "クリップ失敗 \(result.error ?? "")")
        }
        let saved = stats.clipsSaved
        let failed = stats.clipsFailed
        DispatchQueue.main.async {
            self.clipCount = saved
            self.failedClipCount = failed
            if ok { self.lastLatency = latency }
        }
        pruneChunks()
        publishStats()
        completeStopIfDone()
    }

    /// 新しいほうから retainedChunks 個を残し、それより古いものを消す。
    /// 切り出し待ちと連結中のクリップが使うチャンクは消さない
    private func pruneChunks() {
        guard let log, chunks.count > config.retainedChunks else { return }
        let needed = pendingClips + Array(buildingClips.values)
        let now = nowT()
        var removed = Set<Int>()
        for chunk in chunks.prefix(chunks.count - config.retainedChunks) where !needed.contains(where: { $0.needs(chunk) }) {
            do {
                try FileManager.default.removeItem(at: chunk.url)
                removed.insert(chunk.index)
                stats.chunksDeleted += 1
                log.chunk(t: now, event: "deleted", index: chunk.index, startT: chunk.startT, endT: chunk.endT,
                          frames: chunk.frames, bytes: chunk.bytes)
            } catch {
                log.chunk(t: now, event: "delete_failed", index: chunk.index, startT: chunk.startT, endT: chunk.endT,
                          frames: chunk.frames, bytes: chunk.bytes, note: error.localizedDescription)
            }
        }
        chunks.removeAll { removed.contains($0.index) }
    }

    // MARK: - 実打の判定（queue 上）

    private func handle(_ events: [DetectorEvent]) {
        guard let log else { return }
        for event in events {
            switch event {
            case .audioPeak(let peak):
                log.event(t: peak.t, kind: "audio_peak", peak.level)
            case .segment(let segment, let qualified):
                log.event(t: segment.start, kind: "segment", segment.end, segment.peak, qualified ? 1 : 0)
            case .hit(let impact, let segment):
                log.event(t: impact.t, kind: "hit", impact.level, segment.start, segment.end)
                trigger(.hit, impactT: impact.t)
            }
        }
    }

    // MARK: - 終了（queue 上）

    private func abortSession(_ reason: String) {
        log?.event(t: lastT, kind: "error", note: reason)
        beginStop(reason: reason)
    }

    private func beginStop(reason: String?) {
        guard recording else { return }
        // 最後の判定で出た実打もクリップにするため、recording を下ろす前に締める
        if let detector { handle(detector.finish()) }
        recording = false
        stopping = true
        stopReason = reason

        if let active {
            active.endPTS = CMTimeAdd(lastVideoPTS, frameDuration)
            closing.append(active)
            self.active = nil
        }
        flushAudio(upTo: .positiveInfinity)
        pendingAudio = []
        finishClosingChunks(videoPTS: lastVideoPTS, force: true)
        standby?.cancel()
        standby = nil
        buildReadyClips()
        completeStopIfDone()
    }

    /// チャンクがすべて閉じ、クリップがすべて出来上がったら、残りのチャンクを片付けて meta.json を書く
    private func completeStopIfDone() {
        guard stopping, active == nil, closing.isEmpty, finishingChunks == 0 else { return }
        // チャンクが閉じ終わった時点で、待っていたクリップを今あるぶんで作る
        if !pendingClips.isEmpty { buildReadyClips() }
        guard pendingClips.isEmpty, buildingClips.isEmpty, let log else { return }
        stopping = false

        if !config.keepChunksAtEnd {
            let now = nowT()
            for chunk in chunks {
                try? FileManager.default.removeItem(at: chunk.url)
                log.chunk(t: now, event: "deleted_at_end", index: chunk.index, startT: chunk.startT, endT: chunk.endT,
                          frames: chunk.frames, bytes: chunk.bytes)
            }
            chunks = []
            // 使わずに捨てた待機中のライタなどの残り
            let leftovers = (try? FileManager.default.contentsOfDirectory(
                at: log.chunksDirectory, includingPropertiesForKeys: nil)) ?? []
            for url in leftovers { try? FileManager.default.removeItem(at: url) }
        }

        let meta = SessionMeta(
            device: Recorder.machineName(),
            systemVersion: systemVersion,
            videoFormat: videoFormat,
            durationSeconds: lastT,
            videoFrames: stats.videoFrames,
            droppedFrames: stats.droppedFrames,
            audioDroppedBuffers: stats.audioDropped,
            chunksWritten: stats.chunksWritten,
            chunksFailed: stats.chunksFailed,
            chunksDeleted: stats.chunksDeleted,
            standbyMisses: stats.standbyMisses,
            maxChunkFiles: stats.maxChunkFiles,
            maxChunkBytes: stats.maxChunkBytes,
            triggers: stats.triggers,
            clipsSaved: stats.clipsSaved,
            clipsFailed: stats.clipsFailed,
            clipBytesTotal: stats.clipBytes,
            sessionBytesAtEnd: Recorder.directorySize(log.directory),
            stopReason: stopReason)
        log.writeMeta(meta)
        log.close()

        self.log = nil
        detector = nil
        origin = nil
        template = nil
        generation += 1

        let name = log.directory.lastPathComponent
        let reason = stopReason
        let saved = stats.clipsSaved
        DispatchQueue.main.async {
            self.isRunning = false
            self.clipCount = saved
            self.pendingCount = 0
            UIApplication.shared.isIdleTimerDisabled = false
            self.statusText = reason.map { "中断: \($0)（\(name)）" } ?? "保存しました: \(name)"
        }
    }

    // MARK: - 記録の補助（queue 上）

    /// いまの時刻（t の秒）。トリガの時刻と完了の時刻に使う
    private func nowT() -> Double {
        guard let origin else { return lastT }
        return CMTimeSubtract(CMClockGetTime(clock), origin).seconds
    }

    private func sampleDiskIfNeeded(t: Double) {
        guard t - lastDiskT >= config.diskLogIntervalSeconds, !diskSampling, let log else { return }
        lastDiskT = t
        diskSampling = true
        ioQueue.async { [self] in
            let chunkUsage = Recorder.usage(of: log.chunksDirectory)
            let clipUsage = Recorder.usage(of: log.clipsDirectory)
            let free = Recorder.freeBytes(at: log.directory)
            queue.async { [self] in
                diskSampling = false
                guard self.log === log else { return }
                log.disk(t: t, chunkFiles: chunkUsage.files, chunkBytes: chunkUsage.bytes,
                         clipFiles: clipUsage.files, clipBytes: clipUsage.bytes, freeBytes: free)
                stats.maxChunkFiles = max(stats.maxChunkFiles, chunkUsage.files)
                stats.maxChunkBytes = max(stats.maxChunkBytes, chunkUsage.bytes)
                DispatchQueue.main.async {
                    self.chunkFiles = chunkUsage.files
                    self.diskBytes = chunkUsage.bytes + clipUsage.bytes
                }
            }
        }
    }

    private func publishStats() {
        let pending = pendingClips.count + buildingClips.count
        DispatchQueue.main.async { self.pendingCount = pending }
    }

    private func logThermalState() {
        guard recording, origin != nil, let log else { return }
        log.event(t: lastT, kind: "thermal", Double(ProcessInfo.processInfo.thermalState.rawValue))
    }

    private static func audioEnd(of sampleBuffer: CMSampleBuffer, pts: CMTime) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, CMTimeCompare(duration, .zero) > 0 {
            return CMTimeAdd(pts, duration)
        }
        var rate = 48_000.0
        if let format = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee, asbd.mSampleRate > 0 {
            rate = asbd.mSampleRate
        }
        let samples = CMSampleBufferGetNumSamples(sampleBuffer)
        return CMTimeAdd(pts, CMTime(value: CMTimeValue(samples), timescale: CMTimeScale(rate)))
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }

    private static func usage(of directory: URL) -> (files: Int, bytes: Int64) {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return (urls.count, urls.reduce(0) { $0 + fileSize($1) })
    }

    private static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator { total += fileSize(url) }
        return total
    }

    private static func freeBytes(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? -1
    }

    private static func machineName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

extension Recorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else {
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, output === videoOutput, let log else { return }
        stats.droppedFrames += 1
        log.event(t: lastT, kind: "dropped_frame", 0)
    }
}

enum RecorderError: LocalizedError {
    case deviceUnavailable
    case formatUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "カメラまたはマイクを使えません"
        case .formatUnavailable: "1080p/60fps に対応したフォーマットがありません"
        }
    }
}
