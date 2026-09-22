import AVFoundation
import UIKit

struct SessionMeta: Codable {
    var device: String
    var systemVersion: String
    var videoFormat: String
    var audioSampleRate: Double
    var videoFrames: Int
    var droppedFrames: Int
    var durationSeconds: Double
    var appHits: Int
}

/// カメラとマイクを回し、参照動画・ログ・実打判定を同時に行う。
/// 音声は AVCaptureAudioDataOutput から取る。映像と同じ時計に揃い、参照動画の再生位置とログの時刻が一致するため。
final class Recorder: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRunning = false
    @Published private(set) var hitCount = 0
    @Published private(set) var audioLevelDb: Double = -120
    @Published private(set) var motionRatio: Double = 0
    @Published private(set) var statusText = "準備中"

    let session = AVCaptureSession()
    let config = DetectionConfig.default

    private let queue = DispatchQueue(label: "poc01.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let audioMeter: AudioBlockMeter
    private let motionMeter: FrameMotionMeter
    private let roiCells: [Int]
    /// UIDevice はメインアクター隔離なので、キャプチャキューからも読める ProcessInfo で取る
    private let systemVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }()
    private var videoFormat = ""
    private var thermalObserver: NSObjectProtocol?

    // ここから下は queue 上でのみ触る
    private var recording = false
    private var log: SessionLog?
    private var detector: HitDetector?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// 参照動画の0秒にあたるキャプチャ時刻
    private var origin: CMTime?
    private var lastT = 0.0
    private var videoFrames = 0
    private var droppedFrames = 0
    private var appHits = 0
    private var lastUIUpdate = 0.0
    private var uiAudioPeak = -120.0
    private var uiMotionPeak = 0.0

    override init() {
        // super.init() 前に self.config を読まないよう、同じ値をローカルで持つ
        let config = DetectionConfig.default
        audioMeter = AudioBlockMeter(blockSeconds: config.audioBlockSeconds, cutoffHz: config.highPassCutoffHz)
        motionMeter = FrameMotionMeter(config: config)
        roiCells = config.roiCells()
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
        // 参照動画はフレームを落とさず残したい
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
            throw RecorderError.deviceUnavailable
        }
        session.addOutput(videoOutput)
        session.addOutput(audioOutput)

        // 縦向きの画像として受け取る。ROI とセルの座標はこの向きで決まる
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
        let duration = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
        device.unlockForConfiguration()
        videoFormat = "1920x1080@\(config.frameRate)"
    }

    // MARK: - 計測の開始と終了

    @MainActor
    func start() {
        guard isReady, !isRunning else { return }
        isRunning = true
        hitCount = 0
        statusText = "計測中"
        UIApplication.shared.isIdleTimerDisabled = true

        queue.async { [self] in
            do {
                log = try SessionLog(config: config)
            } catch {
                DispatchQueue.main.async {
                    self.isRunning = false
                    self.statusText = "ログを作れません: \(error.localizedDescription)"
                }
                return
            }
            detector = HitDetector(config: config)
            writer = nil
            videoInput = nil
            audioInput = nil
            origin = nil
            lastT = 0
            videoFrames = 0
            droppedFrames = 0
            appHits = 0
            recording = true
        }
    }

    @MainActor
    func stop() {
        guard isRunning else { return }
        statusText = "保存中"
        queue.async { [self] in
            finishRecording(reason: nil)
        }
    }

    /// queue 上で呼ぶ
    private func finishRecording(reason: String?) {
        guard recording else { return }
        recording = false
        if let detector { handle(detector.finish()) }

        let log = self.log
        let meta = SessionMeta(
            device: Recorder.machineName(),
            systemVersion: systemVersion,
            videoFormat: videoFormat,
            audioSampleRate: audioMeter.sampleRate,
            videoFrames: videoFrames,
            droppedFrames: droppedFrames,
            durationSeconds: lastT,
            appHits: appHits)
        let hits = appHits
        let done = {
            log?.writeMeta(meta)
            log?.close()
            DispatchQueue.main.async {
                self.isRunning = false
                self.hitCount = hits
                UIApplication.shared.isIdleTimerDisabled = false
                let name = log?.directory.lastPathComponent ?? ""
                self.statusText = reason.map { "中断: \($0)（\(name)）" } ?? "保存しました: \(name)"
            }
        }

        if let writer, writer.status == .writing {
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting(completionHandler: done)
        } else {
            done()
        }
        self.log = nil
        detector = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    private func startWriter(with pixelBuffer: CVPixelBuffer, at pts: CMTime) throws {
        guard let log else { return }
        let writer = try AVAssetWriter(outputURL: log.referenceVideoURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
            AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: config.videoBitRate,
                AVVideoExpectedSourceFrameRateKey: config.frameRate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        // 戻り値は [AnyHashable: Any]? なので、AVAssetWriterInput が受け取る形に直す
        if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) as? [String: Any] {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        guard writer.startWriting() else { throw writer.error ?? RecorderError.writerFailed }
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.videoInput = videoInput
        origin = pts
    }

    // MARK: - サンプルの処理（queue 上）

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        let started = CACurrentMediaTime()
        let cells = motionMeter.process(pixelBuffer)
        let processingMs = (CACurrentMediaTime() - started) * 1000
        if let cells {
            uiMotionPeak = max(uiMotionPeak, HitDetector.roiRatio(cells, roiCells: roiCells))
        }
        defer { publishUIIfNeeded() }

        guard recording, let log, let detector else { return }
        if writer == nil {
            do {
                try startWriter(with: pixelBuffer, at: pts)
                logThermalState()
            } catch {
                finishRecording(reason: "動画を書き出せません \(error.localizedDescription)")
                return
            }
        }
        guard let origin, let writer, let videoInput else { return }

        let t = CMTimeSubtract(pts, origin).seconds
        lastT = t
        videoFrames += 1
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else {
            droppedFrames += 1
            log.event(t: t, kind: "dropped_frame", 1)
        }
        if writer.status == .failed {
            finishRecording(reason: "動画の書き出しに失敗 \(writer.error?.localizedDescription ?? "")")
            return
        }

        if let cells {
            log.motion(t: t, processingMs: processingMs, cells: cells)
            // replay.py はCSVの丸めた値で判定するので、アプリ内の判定も同じ値で行い、結果を一致させる
            handle(detector.addMotion(t: logged(t, 4), cellRatios: cells.map { logged($0, 4) }))
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        let blocks = audioMeter.process(sampleBuffer)
        for block in blocks {
            uiAudioPeak = max(uiAudioPeak, config.useHighPass ? block.highPassPeakDb : block.peakDb)
        }
        defer { publishUIIfNeeded() }

        guard recording, let log, let detector, let origin else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if CMTimeCompare(pts, origin) >= 0, let audioInput, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }

        let originSeconds = origin.seconds
        for block in blocks {
            let t = block.t - originSeconds
            log.audio(t: t, block: block)
            handle(detector.addAudio(
                t: logged(t, 4), peakDb: logged(block.peakDb, 2), highPassPeakDb: logged(block.highPassPeakDb, 2)))
        }
    }

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
                appHits += 1
                let count = appHits
                DispatchQueue.main.async { self.hitCount = count }
            }
        }
    }

    private func logThermalState() {
        guard recording, origin != nil, let log else { return }
        log.event(t: lastT, kind: "thermal", Double(ProcessInfo.processInfo.thermalState.rawValue))
    }

    private func publishUIIfNeeded() {
        let now = CACurrentMediaTime()
        guard now - lastUIUpdate >= 0.1 else { return }
        lastUIUpdate = now
        let audio = uiAudioPeak
        let motion = uiMotionPeak
        uiAudioPeak = -120
        uiMotionPeak = 0
        DispatchQueue.main.async {
            self.audioLevelDb = audio
            self.motionRatio = motion
        }
    }

    /// SessionLog がCSVに書くのと同じ桁に丸めた値
    private func logged(_ value: Double, _ digits: Int) -> Double {
        Double(String(format: "%.\(digits)f", value)) ?? value
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
        droppedFrames += 1
        log.event(t: lastT, kind: "dropped_frame", 0)
    }
}

enum RecorderError: LocalizedError {
    case deviceUnavailable
    case formatUnavailable
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "カメラまたはマイクを使えません"
        case .formatUnavailable: "1080p/60fps に対応したフォーマットがありません"
        case .writerFailed: "動画の書き出しを開始できません"
        }
    }
}
