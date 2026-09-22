import Foundation

/// 計測1回ぶんのログ一式。Documents/sessions/<日時>/ に書く。
/// 時刻 t はすべて、計測開始後の最初の映像フレームを0とした秒数（キャプチャセッションの時計）。
final class SessionLog {
    let directory: URL
    let chunksDirectory: URL
    let clipsDirectory: URL
    private let eventsCSV: CSVWriter
    private let chunksCSV: CSVWriter
    private let clipsCSV: CSVWriter
    private let diskCSV: CSVWriter

    init(config: SessionConfig) throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        directory = documents
            .appendingPathComponent("sessions")
            .appendingPathComponent(formatter.string(from: Date()))
        chunksDirectory = directory.appendingPathComponent("chunks")
        clipsDirectory = directory.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: chunksDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)

        try SessionLog.writeJSON(config, to: directory.appendingPathComponent("config.json"))
        eventsCSV = try CSVWriter(
            url: directory.appendingPathComponent("events.csv"),
            header: "t,kind,v1,v2,v3,note")
        chunksCSV = try CSVWriter(
            url: directory.appendingPathComponent("chunks.csv"),
            header: "t,event,index,start_t,end_t,frames,bytes,finish_ms,note")
        clipsCSV = try CSVWriter(
            url: directory.appendingPathComponent("clips.csv"),
            header: "clip,source,status,impact_t,trigger_t,buffered_t,done_t,latency_s,detect_delay_s,export_ms,"
                + "requested_start,requested_end,requested_s,covered_start,covered_end,covered_s,actual_s,"
                + "chunks,gaps,bytes,error",
            flushEachLine: true)
        diskCSV = try CSVWriter(
            url: directory.appendingPathComponent("disk.csv"),
            header: "t,chunk_files,chunk_bytes,clip_files,clip_bytes,free_bytes")
    }

    func chunkURL(index: Int) -> URL {
        chunksDirectory.appendingPathComponent(String(format: "chunk_%06d.mov", index))
    }

    func clipURL(number: Int) -> URL {
        clipsDirectory.appendingPathComponent(String(format: "%03d.mov", number))
    }

    /// kind: trigger_hit / trigger_manual / trigger_interval / audio_peak / segment / hit /
    ///       interval_on / interval_off / standby_miss / dropped_frame / audio_dropped / thermal / error
    func event(t: Double, kind: String, _ values: Double..., note: String = "") {
        var columns = values.map { f4($0) }
        while columns.count < 3 { columns.append("") }
        eventsCSV.write("\(f4(t)),\(kind),\(columns.joined(separator: ",")),\(clean(note))")
    }

    /// event: finalized / failed / deleted / delete_failed / deleted_at_end
    func chunk(t: Double, event: String, index: Int, startT: Double, endT: Double,
               frames: Int, bytes: Int64, finishMs: Double? = nil, note: String = "") {
        let ms = finishMs.map { f2($0) } ?? ""
        chunksCSV.write("\(f4(t)),\(event),\(index),\(f4(startT)),\(f4(endT)),\(frames),\(bytes),\(ms),\(clean(note))")
    }

    func clip(_ row: ClipRow) {
        let columns: [String] = [
            "\(row.number)", row.source, row.status,
            f4(row.impactT), f4(row.triggerT), f4(row.bufferedT), f4(row.doneT),
            f4(row.doneT - row.impactT), f4(row.triggerT - row.impactT), f2(row.exportMs),
            f4(row.requestedStart), f4(row.requestedEnd), f4(row.requestedEnd - row.requestedStart),
            row.coveredStart.map { f4($0) } ?? "", row.coveredEnd.map { f4($0) } ?? "",
            f4(max(0, (row.coveredEnd ?? 0) - (row.coveredStart ?? 0))),
            f4(row.actualSeconds), "\(row.chunks)", "\(row.gaps)", "\(row.bytes)", clean(row.error ?? ""),
        ]
        clipsCSV.write(columns.joined(separator: ","))
    }

    func disk(t: Double, chunkFiles: Int, chunkBytes: Int64, clipFiles: Int, clipBytes: Int64, freeBytes: Int64) {
        diskCSV.write("\(f4(t)),\(chunkFiles),\(chunkBytes),\(clipFiles),\(clipBytes),\(freeBytes)")
    }

    func writeMeta<T: Encodable>(_ meta: T) {
        try? SessionLog.writeJSON(meta, to: directory.appendingPathComponent("meta.json"))
    }

    func close() {
        eventsCSV.close()
        chunksCSV.close()
        clipsCSV.close()
        diskCSV.close()
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url)
    }

    /// CSV の1列に収める（カンマと改行を消す）
    private func clean(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: " ").replacingOccurrences(of: "\n", with: " ")
    }

    private func f2(_ v: Double) -> String { String(format: "%.2f", v) }
    private func f4(_ v: Double) -> String { String(format: "%.4f", v) }
}

/// clips.csv の1行
struct ClipRow {
    var number: Int
    var source: String
    /// ok / failed
    var status: String
    var impactT: Double
    var triggerT: Double
    /// 後ろの秒数ぶんがバッファに揃い、連結を始めた時刻
    var bufferedT: Double
    var doneT: Double
    var exportMs: Double
    var requestedStart: Double
    var requestedEnd: Double
    /// ディスク上のチャンクで賄えた範囲
    var coveredStart: Double?
    var coveredEnd: Double?
    var actualSeconds: Double
    var chunks: Int
    /// 使ったチャンクの間の抜け（失敗したチャンクなど）の数
    var gaps: Int
    var bytes: Int64
    var error: String?
}

final class CSVWriter {
    private let handle: FileHandle
    private let flushEachLine: Bool
    private var buffer = ""
    private var bufferedBytes = 0

    init(url: URL, header: String, flushEachLine: Bool = false) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.flushEachLine = flushEachLine
        write(header)
    }

    func write(_ line: String) {
        buffer += line
        buffer += "\n"
        bufferedBytes += line.utf8.count + 1
        if flushEachLine || bufferedBytes >= 1 << 14 { flush() }
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
