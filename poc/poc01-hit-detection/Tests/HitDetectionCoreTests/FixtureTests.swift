import Foundation
import XCTest
@testable import HitDetectionCore

/// tools/replay.py と同じ判定になるかを、tools/make_fixture.py が作ったフィクスチャで確かめる。
/// replay.py はログ全体を一括で判定し、HitDetector は届いた順に逐次判定する。入力を時刻順に流せば結果は一致するはず。
final class FixtureTests: XCTestCase {
    private struct Fixture: Decodable {
        let name: String
        let description: String
        let config: DetectionConfig
        /// t, peak_db, hp_peak_db
        let audio: [[Double]]
        /// t, c0, c1, ...
        let motion: [[Double]]
        let expected: Expected

        struct Expected: Decodable {
            /// t, level
            let peaks: [[Double]]
            /// start, end, peak, スイング候補なら1
            let segments: [[Double]]
            /// インパクト音の t, level, 区間の start, end
            let hits: [[Double]]
        }
    }

    private static let fixturesDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func testMatchesReplayPy() throws {
        let urls = try FileManager.default
            .contentsOfDirectory(at: Self.fixturesDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(urls.isEmpty, "フィクスチャがない。tools/make_fixture.py で作る")

        for url in urls {
            let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
            check(fixture)
        }
    }

    private func check(_ fixture: Fixture) {
        let name = "\(fixture.name)（\(fixture.description)）"
        let cellCount = fixture.config.motionGridCols * fixture.config.motionGridRows
        let audio = fixture.audio.map { AudioRow(t: $0[0], peakDb: $0[1], highPassPeakDb: $0[2]) }
        let motion = fixture.motion.map { MotionRow(t: $0[0], cells: Array($0.dropFirst())) }
        guard motion.allSatisfy({ $0.cells.count == cellCount }) else {
            return XCTFail("\(name): 動きの行のセル数が \(cellCount) ではない")
        }

        let run = DetectorRun.feed(config: fixture.config, audio: audio, motion: motion)
        assertRows(run.peaks.map { [$0.t, $0.level] }, fixture.expected.peaks, "音のピーク", name)
        assertRows(
            run.segments.map { [$0.segment.start, $0.segment.end, $0.segment.peak, $0.qualified ? 1 : 0] },
            fixture.expected.segments, "動きの区間", name)
        assertRows(
            run.hits.map { [$0.impact.t, $0.impact.level, $0.segment.start, $0.segment.end] },
            fixture.expected.hits, "実打", name)
    }

    private func assertRows(
        _ actual: [[Double]], _ expected: [[Double]], _ what: String, _ name: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, "\(name): \(what)の件数 \(actual) / 期待 \(expected)",
                       file: file, line: line)
        for (i, (a, e)) in zip(actual, expected).enumerated() {
            XCTAssertEqual(a.count, e.count, "\(name): \(what)[\(i)] の列数", file: file, line: line)
            for (x, y) in zip(a, e) {
                XCTAssertEqual(x, y, accuracy: 1e-6, "\(name): \(what)[\(i)] \(a) / 期待 \(e)", file: file, line: line)
            }
        }
    }
}
