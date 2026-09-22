import XCTest
@testable import HitDetectionCore

/// tools/test_replay.py の JudgeTest と同じケース
final class HitDetectorTests: XCTestCase {
    func testOwnHitIsSavedAtImpactTime() {
        let r = Scenario().swing(5.0).run()
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.hits.first?.impact.t ?? .nan, 6.2, accuracy: 0.02)
    }

    func testPracticeSwingWithoutSoundIsNotSaved() {
        let r = Scenario().motion(5.0, 7.0, 0.3).run()
        XCTAssertTrue(r.hits.isEmpty)
    }

    func testNeighborHitWithoutOwnMotionIsNotSaved() {
        let r = Scenario().impact(10.0).run()
        XCTAssertEqual(r.peaks.count, 1)
        XCTAssertTrue(r.hits.isEmpty)
    }

    func testWaggleWithNeighborSoundIsNotSaved() {
        // 小さく短い動き（ワッグル）の最中に隣の打球音が鳴っても保存しない
        let r = Scenario().motion(10.0, 10.3, 0.1).impact(10.1).run()
        XCTAssertTrue(r.hits.isEmpty)
    }

    func testSecondPeakOfSameShotIsDebounced() {
        let r = Scenario().swing(5.0, secondPeakAfter: 0.15).run()
        XCTAssertEqual(r.peaks.count, 1)
        XCTAssertEqual(r.hits.count, 1)
    }

    func testLouderSoundInWindowIsTakenAsImpact() {
        // 自分のスイング中に小さい隣の打球音が先に鳴っても、大きい方をインパクトとする
        let r = Scenario().motion(5.0, 7.0, 0.3).impact(5.4, level: -30).impact(6.2, level: -5).run()
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertEqual(r.hits.first?.impact.t ?? .nan, 6.2, accuracy: 0.02)
    }

    func testSoundOutsideWindowIsNotMatched() {
        let scenario = Scenario().motion(5.0, 7.0, 0.3).impact(8.0)
        XCTAssertTrue(scenario.run().hits.isEmpty)

        var widened = DetectionConfig.default
        widened.windowAfterEndSeconds = 1.2
        XCTAssertEqual(scenario.run(widened).hits.count, 1)
    }

    func testRoiExcludesMotionOutside() {
        // ROI を画面上端の細い帯にすると、ROI 外の動きになるので保存しない
        var config = DetectionConfig.default
        config.roi = [0.0, 0.0, 1.0, 0.01]
        XCTAssertTrue(Scenario().swing(5.0).run(config).hits.isEmpty)
    }

    // MARK: 逐次処理ならではの確認（replay.py は一括で判定するので対応するテストはない）

    func testHitIsReportedAsSoonAsWindowCloses() {
        // 計測中に回数を出せるよう、finish() を待たずに時間窓が閉じた時点で実打を出す
        let config = DetectionConfig.default
        let r = Scenario().swing(5.0).run(config)
        XCTAssertEqual(r.hits.count, 1)
        guard let hit = r.hits.first, let reportedAt = hit.reportedAt else {
            return XCTFail("実打が finish() まで出なかった")
        }
        let windowEnd = hit.segment.end + config.windowAfterEndSeconds
        XCTAssertGreaterThanOrEqual(reportedAt, windowEnd)
        XCTAssertLessThan(reportedAt, windowEnd + 0.05)
    }

    func testSegmentStillOpenAtStopIsJudgedOnFinish() {
        // 計測終了の時点で動きの区間が閉じていなくても、finish() で判定する
        let r = Scenario().motion(7.0, 20.0, 0.3).impact(8.0).run(duration: 10)
        XCTAssertEqual(r.hits.count, 1)
        XCTAssertNil(r.hits.first?.reportedAt)
    }

    func testRoiCellsMatchCellCenters() {
        var config = DetectionConfig.default
        config.motionGridCols = 3
        config.motionGridRows = 2
        // セルの中心は x = 1/6, 1/2, 5/6、y = 1/4, 3/4
        config.roi = [0.4, 0.0, 1.0, 0.5]
        XCTAssertEqual(config.roiCells(), [1, 2])
        XCTAssertEqual(HitDetector.roiRatio([0.9, 0.2, 0.4, 0.9, 0.9, 0.9], roiCells: [1, 2]), 0.3, accuracy: 1e-12)
        XCTAssertEqual(HitDetector.roiRatio([0.9], roiCells: []), 0)
    }
}
