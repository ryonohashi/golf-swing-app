import Foundation

/// 計測1回ぶんのログ一式。Documents/sessions/<日時>/ に書く。
/// 時刻 t はすべて参照動画（reference.mov）の再生位置と同じ秒数。
final class SessionLog {
    let directory: URL
    private let audioCSV: CSVWriter
    private let motionCSV: CSVWriter
    private let eventsCSV: CSVWriter

    init(config: DetectionConfig) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        directory = documents
            .appendingPathComponent("sessions")
            .appendingPathComponent(formatter.string(from: Date()))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try SessionLog.writeJSON(config, to: directory.appendingPathComponent("config.json"))
        audioCSV = try CSVWriter(
            url: directory.appendingPathComponent("audio_blocks.csv"),
            header: "t,peak_db,rms_db,hp_peak_db")
        let cellColumns = (0..<(config.motionGridCols * config.motionGridRows)).map { "c\($0)" }
        motionCSV = try CSVWriter(
            url: directory.appendingPathComponent("motion.csv"),
            header: (["t", "proc_ms"] + cellColumns).joined(separator: ","))
        eventsCSV = try CSVWriter(
            url: directory.appendingPathComponent("events.csv"),
            header: "t,kind,v1,v2,v3")
    }

    var referenceVideoURL: URL { directory.appendingPathComponent("reference.mov") }

    func audio(t: Double, block: AudioBlock) {
        audioCSV.write("\(f4(t)),\(f2(block.peakDb)),\(f2(block.rmsDb)),\(f2(block.highPassPeakDb))")
    }

    func motion(t: Double, processingMs: Double, cells: [Double]) {
        let values = cells.map { String(format: "%.4f", $0) }.joined(separator: ",")
        motionCSV.write("\(f4(t)),\(f2(processingMs)),\(values)")
    }

    /// kind: audio_peak / segment / hit / thermal / dropped_frame / error
    func event(t: Double, kind: String, _ values: Double...) {
        var columns = values.map { f4($0) }
        while columns.count < 3 { columns.append("") }
        eventsCSV.write("\(f4(t)),\(kind),\(columns.joined(separator: ","))")
    }

    func writeMeta<T: Encodable>(_ meta: T) {
        try? SessionLog.writeJSON(meta, to: directory.appendingPathComponent("meta.json"))
    }

    func close() {
        audioCSV.close()
        motionCSV.close()
        eventsCSV.close()
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func f4(_ v: Double) -> String { String(format: "%.4f", v) }
}

final class CSVWriter {
    private let handle: FileHandle
    private var buffer = ""
    private var bufferedBytes = 0

    init(url: URL, header: String) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        write(header)
    }

    func write(_ line: String) {
        buffer += line
        buffer += "\n"
        bufferedBytes += line.utf8.count + 1
        if bufferedBytes >= 1 << 16 { flush() }
    }

    func flush() {
        guard !buffer.isEmpty else { return }
        try? handle.write(contentsOf: Data(buffer.utf8))
        buffer = ""
        bufferedBytes = 0
    }

    func close() {
        flush()
        try? handle.close()
    }
}
