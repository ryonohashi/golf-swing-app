"""replay.py のテスト。合成したログで判定と採点を確かめる。

    python -m unittest test_replay.py
"""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

import replay

CONFIG = {
    "frameRate": 60,
    "videoBitRate": 8000000,
    "audioBlockSeconds": 0.01,
    "highPassCutoffHz": 1000,
    "motionGridCols": 6,
    "motionGridRows": 8,
    "motionSampleStep": 8,
    "motionPixelDiffThreshold": 25,
    "useHighPass": True,
    "audioRelativeThresholdDb": 20,
    "audioAbsoluteMinDb": -40,
    "audioFloorTauSeconds": 2.0,
    "audioDebounceSeconds": 0.5,
    "roi": [0.15, 0.05, 0.85, 0.95],
    "motionOnThreshold": 0.08,
    "motionOffThreshold": 0.03,
    "motionOffHoldSeconds": 0.25,
    "minSwingSeconds": 0.4,
    "maxSwingSeconds": 6.0,
    "minSwingPeak": 0.15,
    "windowBeforeStartSeconds": 0.2,
    "windowAfterEndSeconds": 0.3,
}

DURATION = 40.0


class Scenario:
    """合成セッション。音は環境音 -60dB に打球音を足し、動きは ROI 内の全セルに同じ値を入れる。"""

    def __init__(self):
        self.sounds = []  # (t, level)
        self.motions = []  # (start, end, ratio)

    def impact(self, t, level=-10.0, second_peak_after=None):
        self.sounds.append((t, level))
        if second_peak_after is not None:
            self.sounds.append((t + second_peak_after, level - 6))
        return self

    def motion(self, start, end, ratio):
        self.motions.append((start, end, ratio))
        return self

    def swing(self, start, impact_after=1.2, length=2.0, **impact):
        self.motion(start, start + length, 0.3)
        return self.impact(start + impact_after, **impact)

    def write(self, directory: Path):
        (directory / "config.json").write_text(json.dumps(CONFIG), encoding="utf-8")
        with open(directory / "audio_blocks.csv", "w", encoding="utf-8") as f:
            f.write("t,peak_db,rms_db,hp_peak_db\n")
            for i in range(int(DURATION / 0.01)):
                t = i * 0.01
                level = -60.0
                for st, sl in self.sounds:
                    if st <= t < st + 0.03:
                        level = max(level, sl)
                f.write(f"{t:.4f},{level:.2f},{level - 3:.2f},{level:.2f}\n")
        cells = CONFIG["motionGridCols"] * CONFIG["motionGridRows"]
        with open(directory / "motion.csv", "w", encoding="utf-8") as f:
            f.write("t,proc_ms," + ",".join(f"c{i}" for i in range(cells)) + "\n")
            for i in range(1, int(DURATION * 60)):
                t = i / 60
                ratio = 0.005
                for ms, me, mr in self.motions:
                    if ms <= t <= me:
                        ratio = max(ratio, mr)
                f.write(f"{t:.4f},0.50," + ",".join([f"{ratio:.4f}"] * cells) + "\n")


def run_scenario(scenario: Scenario, **overrides):
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp)
        scenario.write(path)
        session = replay.load_session(path)
    cfg = dict(session.config)
    cfg.update(overrides)
    return session, replay.run(session, cfg)


class JudgeTest(unittest.TestCase):
    def test_own_hit_is_saved_at_impact_time(self):
        _, r = run_scenario(Scenario().swing(5.0))
        self.assertEqual(len(r.hits), 1)
        self.assertAlmostEqual(r.hits[0].t, 6.2, delta=0.02)

    def test_practice_swing_without_sound_is_not_saved(self):
        _, r = run_scenario(Scenario().motion(5.0, 7.0, 0.3))
        self.assertEqual(r.hits, [])

    def test_neighbor_hit_without_own_motion_is_not_saved(self):
        _, r = run_scenario(Scenario().impact(10.0))
        self.assertEqual(len(r.peaks), 1)
        self.assertEqual(r.hits, [])

    def test_waggle_with_neighbor_sound_is_not_saved(self):
        # 小さく短い動き（ワッグル）の最中に隣の打球音が鳴っても保存しない
        _, r = run_scenario(Scenario().motion(10.0, 10.3, 0.1).impact(10.1))
        self.assertEqual(r.hits, [])

    def test_second_peak_of_same_shot_is_debounced(self):
        _, r = run_scenario(Scenario().swing(5.0, second_peak_after=0.15))
        self.assertEqual(len(r.peaks), 1)
        self.assertEqual(len(r.hits), 1)

    def test_louder_sound_in_window_is_taken_as_impact(self):
        # 自分のスイング中に小さい隣の打球音が先に鳴っても、大きい方をインパクトとする
        scenario = Scenario().motion(5.0, 7.0, 0.3).impact(5.4, level=-30).impact(6.2, level=-5)
        _, r = run_scenario(scenario)
        self.assertEqual(len(r.hits), 1)
        self.assertAlmostEqual(r.hits[0].t, 6.2, delta=0.02)

    def test_sound_outside_window_is_not_matched(self):
        scenario = Scenario().motion(5.0, 7.0, 0.3).impact(8.0)
        _, r = run_scenario(scenario)
        self.assertEqual(r.hits, [])
        _, widened = run_scenario(scenario, windowAfterEndSeconds=1.2)
        self.assertEqual(len(widened.hits), 1)

    def test_roi_excludes_motion_outside(self):
        # ROI を画面上端の細い帯にすると、ROI 外の動きになるので保存しない
        _, r = run_scenario(Scenario().swing(5.0), roi=[0.0, 0.0, 1.0, 0.01])
        self.assertEqual(r.hits, [])


class ScoreTest(unittest.TestCase):
    def test_score_counts_by_kind(self):
        labels = [
            replay.Label(6.2, "hit"),
            replay.Label(16.2, "hit"),
            replay.Label(26.0, "practice"),
            replay.Label(30.0, "neighbor"),
        ]

        def hit(t):
            return replay.Hit(replay.AudioPeak(t, -10), replay.Segment(t - 1, t + 1, 0.3))

        hits = [hit(6.25), hit(6.3), hit(26.5), hit(35.0)]
        sc = replay.score(hits, labels, tol_sound=0.5, tol_motion=2.0)
        self.assertEqual(sc.hit_labels, 2)
        self.assertEqual(sc.saved_hits, 1)
        self.assertEqual(dict(sc.false_saves), {"duplicate": 1, "practice": 1, "unlabeled": 1})
        self.assertAlmostEqual(sc.recall, 0.5)
        self.assertAlmostEqual(sc.false_ratio, 1.5)

    def test_parse_time(self):
        self.assertAlmostEqual(replay.parse_time("83.4"), 83.4)
        self.assertAlmostEqual(replay.parse_time("1:23.4"), 83.4)
        self.assertAlmostEqual(replay.parse_time("0:01:23.4"), 83.4)


class CommandLineTest(unittest.TestCase):
    def test_end_to_end_with_labels_and_sweep(self):
        scenario = (
            Scenario()
            .swing(2.0)
            .swing(12.0, second_peak_after=0.12)
            .motion(22.0, 24.0, 0.3)  # 素振り
            .impact(30.0)  # 隣の打席
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            scenario.write(path)
            (path / "labels.csv").write_text(
                "t,kind,note\n3.2,hit,\n0:13.2,hit,\n23.0,practice,\n30.0,neighbor,\n", encoding="utf-8")

            out = io.StringIO()
            with redirect_stdout(out):
                replay.main([str(path)])
            self.assertIn("実打の保存率: 2/2 = 100.0%", out.getvalue())
            self.assertIn("判定: 合格", out.getvalue())
            self.assertIn("1回=1球, 2回=1球", out.getvalue())

            out = io.StringIO()
            with redirect_stdout(out):
                replay.main([str(path), "--set", "audioAbsoluteMinDb=-40,0", "--set", "roi=0.15:0.05:0.85:0.95"])
            self.assertIn("2 通り中 合格 1 通り", out.getvalue())
            self.assertIn("音のピークなし", self._single(path, "audioAbsoluteMinDb=0"))

    def _single(self, path, setting):
        out = io.StringIO()
        with redirect_stdout(out):
            replay.main([str(path), "--set", setting])
        return out.getvalue()


if __name__ == "__main__":
    unittest.main()
