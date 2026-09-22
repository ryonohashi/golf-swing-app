import Foundation

/// 計測の途中で端末の状態を1回ぶん切り取ったもの。メインスレッドで作り、記録用のキューに渡す。
struct DeviceSnapshot {
    /// 計測開始ボタンからの経過秒（壁時計）
    var elapsed: Double
    var thermalState: Int
    /// 0〜1。取れない時は -1
    var batteryLevel: Double
    /// UIDevice.BatteryState の rawValue（0 unknown / 1 unplugged / 2 charging / 3 full）
    var batteryState: Int
    var dimmed: Bool
    var brightness: Double
}

struct RunMeta: Codable {
    var device: String
    var systemVersion: String
    var requestedFrameRate: Int
    var initialFrameRate: Int
    var finalFrameRate: Int
    var format: String
    /// 希望どおりのフォーマットが無く、解像度や fps を下げた時の説明。下げていなければ空
    var formatNote: String
    var videoBitRate: Int
    var motionMeterEnabled: Bool
    var elapsedSeconds: Double
    var videoSeconds: Double
    var videoFrames: Int
    var droppedCaptureFrames: Int
    var droppedWriterFrames: Int
    var fileBytes: Int64
    var fpsChanges: Int
    /// running（書きかけ。アプリが落ちるとこのまま残る） / manual / session_limit / writer_failed / start_failed
    var stopReason: String
}

/// 計測1回ぶんのログ一式。Documents/sessions/<日時>/ に書く。
/// 行数が少ないので1行ごとにファイルへ書き出す。発熱でアプリが落ちても、そこまでの記録が残る。
final class RunLog {
    let directory: URL
    private let statusCSV: LineFile
    private let eventsCSV: LineFile

    init(config: CaptureConfig) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        directory = documents
            .appendingPathComponent("sessions")
            .appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try RunLog.writeJSON(config, to: directory.appendingPathComponent("config.json"))
        statusCSV = try LineFile(
            url: directory.appendingPathComponent("status.csv"),
            header: "elapsed_s,t,thermal,pressure,battery,battery_state,dim,brightness,"
                + "fps_setting,fps_delivered,frames,dropped_capture,dropped_writer,file_bytes,motion_ms")
        eventsCSV = try LineFile(
            url: directory.appendingPathComponent("events.csv"),
            header: "elapsed_s,t,kind,v1,v2,v3")
    }

    var videoURL: URL { directory.appendingPathComponent("session.mov") }

    struct StatusRow {
        var snapshot: DeviceSnapshot
        var t: Double
        var pressure: Int
        var fpsSetting: Int
        var fpsDelivered: Double
        var frames: Int
        var droppedCapture: Int
        var droppedWriter: Int
        var fileBytes: Int64
        /// 動き検出の1フレームあたりの平均処理時間。止めている時は -1
        var motionMs: Double
    }

    func status(_ row: StatusRow) {
        let s = row.snapshot
        let columns = [
            f2(s.elapsed), f4(row.t), "\(s.thermalState)", "\(row.pressure)",
            f4(s.batteryLevel), "\(s.batteryState)", s.dimmed ? "1" : "0", f2(s.brightness),
            "\(row.fpsSetting)", f2(row.fpsDelivered), "\(row.frames)",
            "\(row.droppedCapture)", "\(row.droppedWriter)", "\(row.fileBytes)", f2(row.motionMs),
        ]
        statusCSV.write(columns.joined(separator: ","))
    }

    /// kind:
    /// - start: v1 希望 fps, v2 実際の fps, v3 動き検出 1/0
    /// - thermal: v1 ProcessInfo.ThermalState（0〜3）
    /// - pressure: v1 カメラの systemPressureState（0 nominal 〜 4 shutdown）, v2 要因のビット
    /// - fps_change: v1 変更前, v2 変更後, v3 その時の thermal
    /// - fps_change_failed: v1 変更しようとした fps, v3 その時の thermal
    /// - dim: v1 1/0
    /// - interrupted: v1 AVCaptureSession.InterruptionReason / interruption_ended
    /// - runtime_error: v1 エラーコード
    /// - stop: v1 0 手動 / 1 上限 / 2 書き出し失敗
    func event(elapsed: Double, t: Double, kind: String, _ values: Double...) {
        var columns = values.map { f4($0) }
        while columns.count < 3 { columns.append("") }
        eventsCSV.write("\(f2(elapsed)),\(f4(t)),\(kind),\(columns.joined(separator: ","))")
    }

    func writeMeta(_ meta: RunMeta) {
        try? RunLog.writeJSON(meta, to: directory.appendingPathComponent("meta.json"))
    }

    func videoFileBytes() -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: videoURL.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func close() {
        statusCSV.close()
        eventsCSV.close()
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func f4(_ v: Double) -> String { String(format: "%.4f", v) }
}

/// 1行書くたびにファイルへ書き出す CSV。
final class LineFile {
    private let handle: FileHandle

    init(url: URL, header: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        write(header)
    }

    func write(_ line: String) {
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    func close() {
        try? handle.close()
    }
}
