import AVFoundation
import UIKit

enum StopReason: String {
    case manual
    case sessionLimit = "session_limit"
    case writerFailed = "writer_failed"

    var code: Double {
        switch self {
        case .manual: 0
        case .sessionLimit: 1
        case .writerFailed: 2
        }
    }
}

/// カメラとマイクを回し続けて1本の動画に書き、発熱・電池・実際の fps を一定間隔で記録する。
///
/// スレッドの分担:
/// - メインスレッド: 画面、電池（UIDevice）、画面の明るさ、1秒ごとの tick
/// - queue: キャプチャのサンプル、書き出し、発熱時の fps 変更、ログの書き込み
final class ThermalRecorder: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isRunning = false
    @Published private(set) var elapsedSeconds: Double = 0
    @Published private(set) var thermalState = ProcessInfo.processInfo.thermalState
    @Published private(set) var batteryLevel: Float = -1
    @Published private(set) var currentFrameRate = 0
    @Published private(set) var deliveredFps: Double = 0
    @Published private(set) var statusText = "準備中"
    /// 開始前に画面で変える。計測中は queue 側のコピー（active）を使う
    @Published var config = CaptureConfig.default

    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "poc03.capture")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private var observers: [NSObjectProtocol] = []
    private var pressureObservation: NSKeyValueObservation?

    // ここから下はメインスレッドでのみ触る
    private var startTime: CFTimeInterval = 0
    private var nextLogAt: Double = 0
    private var isStopping = false
    private var savedBrightness: Double?

    // ここから下は queue 上でのみ触る
    private var camera: AVCaptureDevice?
    private var active = CaptureConfig.default
    private var recording = false
    private var log: RunLog?
    private var motionMeter: FrameMotionMeter?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    /// フォーマットを切り替える前に出たフレームを捨てるための時刻
    private var ignoreBefore: CMTime?
    /// 動画の0秒にあたるキャプチャ時刻
    private var origin: CMTime?
    private var meta: RunMeta?
    private var lastT = 0.0
    /// 計測開始ボタンを押した時刻（CACurrentMediaTime）。イベントの経過秒に使う
    private var startHostTime: CFTimeInterval = 0
    /// 書き出しに失敗した後はフレームを受け取らない
    private var failed = false
    private var fps = 0
    private var pressureLevel = 0
    /// ここまでの発熱状態では降格済み。降格したら上がった段、戻したら -1
    private var downgradedAtState = -1
    private var videoFrames = 0
    private var droppedCapture = 0
    private var droppedWriter = 0
    private var intervalFrames = 0
    private var intervalMotionMs = 0.0
    private var intervalMotionCount = 0
    private var lastRowElapsed = 0.0

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            let state = ProcessInfo.processInfo.thermalState
            DispatchQueue.main.async { self.thermalState = state }
            queue.async { self.thermalStateChanged(state.rawValue) }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.doubleValue ?? -1
            queue.async { self.logEvent("interrupted", reason) }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            queue.async { self.logEvent("interruption_ended") }
        })
        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] note in
            guard let self else { return }
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? -1
            queue.async { self.logEvent("runtime_error", Double(code)) }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - 準備

    @MainActor
    func prepare() async {
        guard !isReady else { return }
        UIDevice.current.isBatteryMonitoringEnabled = true
        batteryLevel = UIDevice.current.batteryLevel
        let video = await AVCaptureDevice.requestAccess(for: .video)
        let audio = await AVCaptureDevice.requestAccess(for: .audio)
        guard video, audio else {
            statusText = "カメラとマイクの許可が必要です"
            return
        }
        let requested = config.frameRate
        let settings = config
        queue.async { [self] in
            do {
                try configureSession()
                active = settings
                let selected = try switchFormat(to: requested)
                session.startRunning()
                DispatchQueue.main.async {
                    self.isReady = true
                    self.currentFrameRate = selected.frameRate
                    self.statusText = "待機中 \(selected.description)"
                }
            } catch {
                DispatchQueue.main.async { self.statusText = "カメラを開けません: \(error.localizedDescription)" }
            }
        }
    }

    /// 計測前に fps を選び直した時。プレビューも選んだ fps で回す
    @MainActor
    func frameRateChosen(_ requested: Int) {
        guard isReady, !isRunning else { return }
        let settings = config
        queue.async { [self] in
            active = settings
            let text: String
            let rate: Int
            do {
                let selected = try switchFormat(to: requested)
                text = "待機中 \(selected.description)"
                rate = selected.frameRate
            } catch {
                text = "フォーマットを変えられません: \(error.localizedDescription)"
                rate = fps
            }
            DispatchQueue.main.async {
                self.currentFrameRate = rate
                self.statusText = text
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .inputPriority

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let microphone = AVCaptureDevice.default(for: .audio)
        else { throw ThermalRecorderError.deviceUnavailable }
        self.camera = camera

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        let microphoneInput = try AVCaptureDeviceInput(device: microphone)
        guard session.canAddInput(cameraInput), session.canAddInput(microphoneInput) else {
            throw ThermalRecorderError.deviceUnavailable
        }
        session.addInput(cameraInput)
        session.addInput(microphoneInput)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        // 落ちたフレームを数えたいので、遅れたフレームも捨てずに渡してもらう（POC-01 と同じ）
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(audioOutput) else {
            throw ThermalRecorderError.deviceUnavailable
        }
        session.addOutput(videoOutput)
        session.addOutput(audioOutput)

        // 縦向きの画像として受け取る（POC-01 と同じ向き）
        if let connection = videoOutput.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        // カメラ側の負荷の状態。thermalState と別に、カメラが自分で止まる手前かどうかが分かる
        pressureObservation = camera.observe(\.systemPressureState, options: [.new]) { [weak self] device, _ in
            guard let self else { return }
            let state = device.systemPressureState
            let level = ThermalRecorder.levelNumber(state.level)
            let factors = Double(state.factors.rawValue)
            queue.async {
                self.pressureLevel = level
                self.logEvent("pressure", Double(level), factors)
            }
        }
        pressureLevel = ThermalRecorder.levelNumber(camera.systemPressureState.level)
    }

    // MARK: - フォーマットと fps（queue 上）

    struct SelectedFormat {
        var width: Int
        var height: Int
        var frameRate: Int
        var binned: Bool
        var note: String

        var description: String {
            "\(width)x\(height)@\(frameRate)\(binned ? " binned" : "")"
        }
    }

    /// 希望の fps を出せるフォーマットに切り替える。
    /// 1. 優先解像度（1080p）で出せればそれ
    /// 2. 出せなければ minFallbackWidth までの範囲で、出せる一番大きい解像度
    /// 3. それも無ければ優先解像度のまま、出せる一番高い fps
    /// どれを使ったかは meta.json と status.csv に残る
    private func switchFormat(to requested: Int) throws -> SelectedFormat {
        guard let camera else { throw ThermalRecorderError.deviceUnavailable }
        let target = Double(requested)
        let formats = camera.formats.filter {
            let subtype = CMFormatDescriptionGetMediaSubType($0.formatDescription)
            return subtype == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                || subtype == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }

        func size(_ format: AVCaptureDevice.Format) -> (Int, Int) {
            let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (Int(d.width), Int(d.height))
        }
        func maxRate(_ format: AVCaptureDevice.Format) -> Double {
            format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        }
        // 119.88 のような表記ゆれを許す
        func supports(_ format: AVCaptureDevice.Format) -> Bool { maxRate(format) >= target - 0.5 }
        func isPreferredSize(_ format: AVCaptureDevice.Format) -> Bool {
            size(format) == (active.preferredWidth, active.preferredHeight)
        }
        // 同じ条件ならフルレンジ、ビニングなしを優先する
        func rank(_ format: AVCaptureDevice.Format) -> Int {
            let fullRange = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            return (fullRange ? 2 : 0) + (format.isVideoBinned ? 0 : 1)
        }
        func best(_ list: [AVCaptureDevice.Format]) -> AVCaptureDevice.Format? {
            list.max { rank($0) < rank($1) }
        }

        var chosen: AVCaptureDevice.Format?
        var fpsToSet = requested
        var note = ""
        if let format = best(formats.filter { isPreferredSize($0) && supports($0) }) {
            chosen = format
        } else {
            let smaller = formats.filter {
                let (w, h) = size($0)
                return w <= active.preferredWidth && h <= active.preferredHeight
                    && w >= active.minFallbackWidth && supports($0)
            }
            let largestArea = smaller.map { size($0).0 * size($0).1 }.max()
            if let largestArea, let format = best(smaller.filter { size($0).0 * size($0).1 == largestArea }) {
                chosen = format
                let (w, h) = size(format)
                note = "\(active.preferredWidth)x\(active.preferredHeight)で\(requested)fpsが出ないため\(w)x\(h)を使用"
            } else {
                let preferred = formats.filter { isPreferredSize($0) }
                let topRate = preferred.map(maxRate).max()
                if let topRate, let format = best(preferred.filter { maxRate($0) == topRate }) {
                    chosen = format
                    fpsToSet = Int(topRate.rounded(.down))
                    note = "\(requested)fpsに対応するフォーマットが無いため\(fpsToSet)fpsで撮影"
                }
            }
        }
        guard let format = chosen else { throw ThermalRecorderError.formatUnavailable }

        try camera.lockForConfiguration()
        camera.activeFormat = format
        camera.unlockForConfiguration()
        // activeFormat を変えると fps が既定に戻るので、そのあとで設定する
        let actual = try applyFrameRate(fpsToSet)
        let (w, h) = size(format)
        return SelectedFormat(width: w, height: h, frameRate: actual, binned: format.isVideoBinned, note: note)
    }

    /// 今のフォーマットのまま fps だけ変える。フォーマットが対応する範囲に丸めて、実際に設定した fps を返す
    @discardableResult
    private func applyFrameRate(_ requested: Int) throws -> Int {
        guard let camera else { throw ThermalRecorderError.deviceUnavailable }
        let ranges = camera.activeFormat.videoSupportedFrameRateRanges
        let target = Double(requested)
        guard let range = ranges.first(where: { $0.minFrameRate <= target && target <= $0.maxFrameRate + 0.5 })
                ?? ranges.max(by: { $0.maxFrameRate < $1.maxFrameRate })
        else { throw ThermalRecorderError.formatUnavailable }

        // 範囲外の値を入れると例外で落ちるので、必ず範囲内に丸める
        var duration = CMTime(value: 1, timescale: CMTimeScale(requested))
        if CMTimeCompare(duration, range.minFrameDuration) < 0 { duration = range.minFrameDuration }
        if CMTimeCompare(duration, range.maxFrameDuration) > 0 { duration = range.maxFrameDuration }

        try camera.lockForConfiguration()
        camera.activeVideoMinFrameDuration = duration
        camera.activeVideoMaxFrameDuration = duration
        camera.unlockForConfiguration()
        fps = Int((1 / duration.seconds).rounded())
        return fps
    }

    // MARK: - 計測の開始と終了（メインスレッド）

    @MainActor
    func start() {
        guard isReady, !isRunning else { return }
        isRunning = true
        isStopping = false
        elapsedSeconds = 0
        deliveredFps = 0
        statusText = "計測中"
        startTime = CACurrentMediaTime()
        nextLogAt = 0
        UIApplication.shared.isIdleTimerDisabled = true
        if config.dimScreen { setScreenDimmed(true) }

        let settings = config
        let snapshot = makeSnapshot()
        let hostTime = startTime
        queue.async { [self] in
            do {
                try begin(settings, snapshot: snapshot, hostTime: hostTime)
            } catch {
                recording = false
                log?.close()
                log = nil
                let message = error.localizedDescription
                Task { @MainActor in self.abort("開始できません: \(message)") }
            }
        }
    }

    @MainActor
    func stop(reason: StopReason = .manual) {
        guard isRunning, !isStopping else { return }
        isStopping = true
        statusText = "保存中"
        let snapshot = makeSnapshot()
        setScreenDimmed(false)
        queue.async { [self] in
            finish(reason: reason, snapshot: snapshot)
        }
    }

    /// 1秒ごとに画面から呼ぶ。表示の更新、logIntervalSeconds ごとの記録、セッション長の上限
    @MainActor
    func tick() {
        batteryLevel = UIDevice.current.batteryLevel
        thermalState = ProcessInfo.processInfo.thermalState
        guard isRunning, !isStopping else { return }

        let snapshot = makeSnapshot()
        elapsedSeconds = snapshot.elapsed
        if snapshot.elapsed >= nextLogAt {
            nextLogAt = snapshot.elapsed + config.logIntervalSeconds
            queue.async { [self] in writeStatus(snapshot) }
        }
        if config.sessionLimitMinutes > 0, snapshot.elapsed >= config.sessionLimitMinutes * 60 {
            stop(reason: .sessionLimit)
        }
    }

    /// 画面の「暗くする」を切り替えた時
    @MainActor
    func dimChanged(_ on: Bool) {
        guard isRunning, !isStopping else { return }
        setScreenDimmed(on)
        queue.async { [self] in logEvent("dim", on ? 1 : 0) }
    }

    /// アプリが前面から外れた時は明るさを戻し、戻ってきたら暗転をやり直す
    @MainActor
    func sceneActiveChanged(_ isActive: Bool) {
        if !isActive {
            setScreenDimmed(false)
        } else if isRunning, !isStopping, config.dimScreen {
            setScreenDimmed(true)
        }
    }

    @MainActor
    private func abort(_ message: String) {
        isRunning = false
        setScreenDimmed(false)
        UIApplication.shared.isIdleTimerDisabled = false
        statusText = message
    }

    @MainActor
    private func makeSnapshot() -> DeviceSnapshot {
        let device = UIDevice.current
        return DeviceSnapshot(
            elapsed: CACurrentMediaTime() - startTime,
            thermalState: ProcessInfo.processInfo.thermalState.rawValue,
            batteryLevel: Double(device.batteryLevel),
            batteryState: device.batteryState.rawValue,
            dimmed: savedBrightness != nil,
            brightness: Double(screen?.brightness ?? -1))
    }

    @MainActor
    private var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.screen
    }

    /// 明るさを下げる前の値を覚えておき、戻す時に使う
    @MainActor
    private func setScreenDimmed(_ on: Bool) {
        guard let screen else { return }
        if on {
            if savedBrightness == nil { savedBrightness = Double(screen.brightness) }
            screen.brightness = CGFloat(config.dimBrightness)
        } else if let saved = savedBrightness {
            screen.brightness = CGFloat(saved)
            savedBrightness = nil
        }
    }

    // MARK: - 計測の開始と終了（queue 上）

    private func begin(_ settings: CaptureConfig, snapshot: DeviceSnapshot, hostTime: CFTimeInterval) throws {
        active = settings
        let log = try RunLog(config: settings)
        self.log = log
        let selected = try switchFormat(to: settings.frameRate)
        // フォーマットを変える前に撮られたフレームは動画に入れない
        ignoreBefore = CMClockGetTime(session.synchronizationClock ?? CMClockGetHostTimeClock())

        motionMeter = settings.motionMeterEnabled ? FrameMotionMeter(config: settings.motion) : nil
        writer = nil
        videoInput = nil
        audioInput = nil
        origin = nil
        lastT = 0
        startHostTime = hostTime
        failed = false
        downgradedAtState = -1
        videoFrames = 0
        droppedCapture = 0
        droppedWriter = 0
        intervalFrames = 0
        intervalMotionMs = 0
        intervalMotionCount = 0
        lastRowElapsed = snapshot.elapsed
        recording = true

        meta = RunMeta(
            device: ThermalRecorder.machineName(),
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            requestedFrameRate: settings.frameRate,
            initialFrameRate: selected.frameRate,
            finalFrameRate: selected.frameRate,
            format: selected.description,
            formatNote: selected.note,
            videoBitRate: settings.bitRate(for: selected.frameRate),
            motionMeterEnabled: settings.motionMeterEnabled,
            elapsedSeconds: 0,
            videoSeconds: 0,
            videoFrames: 0,
            droppedCaptureFrames: 0,
            droppedWriterFrames: 0,
            fileBytes: 0,
            fpsChanges: 0,
            stopReason: "running")
        if let meta { log.writeMeta(meta) }

        logEvent("start", Double(settings.frameRate), Double(selected.frameRate), settings.motionMeterEnabled ? 1 : 0)
        logEvent("thermal", Double(snapshot.thermalState))
        logEvent("pressure", Double(pressureLevel))
        if snapshot.dimmed { logEvent("dim", 1) }
        // 開始時点ですでに熱い場合もここで降格する
        applyThermalPolicy(snapshot.thermalState)

        let text = selected.note.isEmpty ? "計測中 \(selected.description)" : "計測中 \(selected.description)（\(selected.note)）"
        let rate = selected.frameRate
        DispatchQueue.main.async {
            self.currentFrameRate = rate
            self.statusText = text
        }
    }

    private func finish(reason: StopReason, snapshot: DeviceSnapshot) {
        guard recording, let log else { return }
        writeStatus(snapshot)
        logEvent("stop", reason.code)
        recording = false

        var updated = self.meta
        updated?.stopReason = reason.rawValue
        updated?.finalFrameRate = fps
        updated?.elapsedSeconds = snapshot.elapsed
        updated?.videoSeconds = lastT
        updated?.videoFrames = videoFrames
        updated?.droppedCaptureFrames = droppedCapture
        updated?.droppedWriterFrames = droppedWriter
        let meta = updated

        let reasonText: String? = switch reason {
        case .manual: nil
        case .sessionLimit: "上限の時間に達しました"
        case .writerFailed: "動画の書き出しに失敗 \(writer?.error?.localizedDescription ?? "")"
        }
        let done = {
            // ファイルサイズは書き終えてから測る
            if var meta {
                meta.fileBytes = log.videoFileBytes()
                log.writeMeta(meta)
            }
            log.close()
            DispatchQueue.main.async {
                self.isRunning = false
                self.isStopping = false
                UIApplication.shared.isIdleTimerDisabled = false
                let name = log.directory.lastPathComponent
                self.statusText = reasonText.map { "終了: \($0)（\(name)）" } ?? "保存しました: \(name)"
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
        self.meta = nil
        motionMeter = nil
        writer = nil
        videoInput = nil
        audioInput = nil
    }

    private func startWriter(with pixelBuffer: CVPixelBuffer, at pts: CMTime) throws {
        guard let log else { return }
        let writer = try AVAssetWriter(outputURL: log.videoURL, fileType: .mov)
        // 一定間隔で目次を書く。発熱でアプリが落ちても、そこまでの動画は再生できる
        writer.movieFragmentInterval = CMTime(seconds: active.movieFragmentSeconds, preferredTimescale: 600)
        // ビットレートと想定 fps は開始時の値で固定する。途中で fps を下げても書き出し器は作り直さない
        //（下の handleVideo のコメント参照）
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: CVPixelBufferGetWidth(pixelBuffer),
            AVVideoHeightKey: CVPixelBufferGetHeight(pixelBuffer),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: active.bitRate(for: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        if let settings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            audioInput.expectsMediaDataInRealTime = true
            if writer.canAdd(audioInput) {
                writer.add(audioInput)
                self.audioInput = audioInput
            }
        }

        guard writer.startWriting() else { throw writer.error ?? ThermalRecorderError.writerFailed }
        writer.startSession(atSourceTime: pts)
        self.writer = writer
        self.videoInput = videoInput
        origin = pts
    }

    // MARK: - 記録（queue 上）

    private func writeStatus(_ snapshot: DeviceSnapshot) {
        guard recording, let log else { return }
        let span = snapshot.elapsed - lastRowElapsed
        let delivered = span > 0 ? Double(intervalFrames) / span : 0
        let motionMs = motionMeter == nil ? -1 : (intervalMotionCount > 0 ? intervalMotionMs / Double(intervalMotionCount) : 0)
        log.status(RunLog.StatusRow(
            snapshot: snapshot,
            t: lastT,
            pressure: pressureLevel,
            fpsSetting: fps,
            fpsDelivered: delivered,
            frames: videoFrames,
            droppedCapture: droppedCapture,
            droppedWriter: droppedWriter,
            fileBytes: log.videoFileBytes(),
            motionMs: motionMs))
        intervalFrames = 0
        intervalMotionMs = 0
        intervalMotionCount = 0
        lastRowElapsed = snapshot.elapsed
        DispatchQueue.main.async { self.deliveredFps = delivered }
    }

    /// t は直前に受け取ったフレームの動画上の位置。動画と突き合わせる時は t を使う
    private func logEvent(_ kind: String, _ values: Double...) {
        guard recording, let log else { return }
        let elapsed = CACurrentMediaTime() - startHostTime
        switch values.count {
        case 0: log.event(elapsed: elapsed, t: lastT, kind: kind)
        case 1: log.event(elapsed: elapsed, t: lastT, kind: kind, values[0])
        case 2: log.event(elapsed: elapsed, t: lastT, kind: kind, values[0], values[1])
        default: log.event(elapsed: elapsed, t: lastT, kind: kind, values[0], values[1], values[2])
        }
    }

    private func thermalStateChanged(_ state: Int) {
        guard recording else { return }
        logEvent("thermal", Double(state))
        applyThermalPolicy(state)
    }

    /// 発熱状態が downgradeThermalState 以上に上がるたびに fps を一段下げる。
    /// 同じ段のまま上下しても二度は下げない。restoreAfterCooling なら冷えた時に開始時の fps に戻す
    private func applyThermalPolicy(_ state: Int) {
        guard recording, active.autoDowngrade, let initial = meta?.initialFrameRate else { return }
        if state >= active.downgradeThermalState, state > downgradedAtState {
            downgradedAtState = state
            if let next = active.downgradeSteps[String(fps)] {
                changeFrameRate(to: next, thermal: state)
            }
        } else if active.restoreAfterCooling, state <= active.restoreThermalState, fps != initial {
            downgradedAtState = -1
            changeFrameRate(to: initial, thermal: state)
        }
    }

    private func changeFrameRate(to target: Int, thermal: Int) {
        let before = fps
        do {
            let after = try applyFrameRate(target)
            guard after != before else { return }
            meta?.fpsChanges += 1
            meta?.finalFrameRate = after
            if let meta { log?.writeMeta(meta) }
            logEvent("fps_change", Double(before), Double(after), Double(thermal))
            DispatchQueue.main.async { self.currentFrameRate = after }
        } catch {
            logEvent("fps_change_failed", Double(target), 0, Double(thermal))
        }
    }

    // MARK: - サンプルの処理（queue 上）

    /// fps を途中で下げても書き出し器（AVAssetWriter）は作り直さない。
    /// フレームの表示時刻は各サンプルのタイムスタンプで決まるので、間隔が 1/120 から 1/60 に変わっても
    /// 可変フレームレートの動画として正しい速さで再生される。解像度と向きは変わらないので同じ入力のまま書ける。
    /// 作り直すと切り替えの前後でファイルが分かれ、切り替え中のフレームも落ちる。
    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard recording, !failed, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let ignoreBefore, CMTimeCompare(pts, ignoreBefore) < 0 { return }

        if let motionMeter {
            let started = CACurrentMediaTime()
            _ = motionMeter.process(pixelBuffer)
            intervalMotionMs += (CACurrentMediaTime() - started) * 1000
            intervalMotionCount += 1
        }

        if writer == nil {
            do {
                try startWriter(with: pixelBuffer, at: pts)
            } catch {
                failWriting()
                return
            }
        }
        guard let origin, let writer, let videoInput else { return }

        lastT = CMTimeSubtract(pts, origin).seconds
        videoFrames += 1
        intervalFrames += 1
        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        } else {
            droppedWriter += 1
        }
        if writer.status == .failed {
            failWriting()
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        guard recording, !failed, let origin, let audioInput else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if CMTimeCompare(pts, origin) >= 0, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    /// 書き出しに失敗したら、そこまでの記録を閉じて計測を終える
    /// 以降のフレームは受け取らず、最後の行と meta.json を書く通常の終了処理に回す
    private func failWriting() {
        guard !failed else { return }
        failed = true
        Task { @MainActor in
            self.stop(reason: .writerFailed)
        }
    }

    private static func levelNumber(_ level: AVCaptureDevice.SystemPressureState.Level) -> Int {
        switch level {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        case .shutdown: 4
        default: -1
        }
    }

    private static func machineName() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

extension ThermalRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === videoOutput {
            handleVideo(sampleBuffer)
        } else {
            handleAudio(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recording, output === videoOutput else { return }
        droppedCapture += 1
    }
}

enum ThermalRecorderError: LocalizedError {
    case deviceUnavailable
    case formatUnavailable
    case writerFailed

    var errorDescription: String? {
        switch self {
        case .deviceUnavailable: "カメラまたはマイクを使えません"
        case .formatUnavailable: "使えるフォーマットがありません"
        case .writerFailed: "動画の書き出しを開始できません"
        }
    }
}
