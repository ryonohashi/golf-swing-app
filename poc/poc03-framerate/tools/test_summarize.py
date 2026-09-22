"""summarize.py のテスト。合成したセッションフォルダで集計を確かめる。

    python -m unittest test_summarize.py
"""

import io
import json
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import summarize

STATUS_HEADER = ("elapsed_s,t,thermal,pressure,battery,battery_state,dim,brightness,"
                 "fps_setting,fps_delivered,frames,dropped_capture,dropped_writer,file_bytes,motion_ms")


def make_session(root: Path, name: str, *, minutes: int, fps: int, dim: bool,
                 serious_at: float | None = None, critical_at: float | None = None,
                 downgrade_to: int | None = None, charging_until: float = 0,
                 with_meta: bool = True, truncated_last_line: bool = False) -> Path:
    """10秒ごとの行を持つセッション。電池は 1時間で 30% 減る。ファイルは fps に比例して増える"""
    path = root / name
    path.mkdir()
    (path / "config.json").write_text(json.dumps({
        "frameRate": fps, "motionMeterEnabled": True, "dimScreen": dim, "logIntervalSeconds": 10,
    }), encoding="utf-8")

    events = ["elapsed_s,t,kind,v1,v2,v3", f"0.00,0.0000,start,{fps},{fps},1", "0.00,0.0000,thermal,0,,"]
    if serious_at is not None:
        events.append(f"{serious_at:.2f},{serious_at:.4f},thermal,2,,")
        if downgrade_to:
            events.append(f"{serious_at:.2f},{serious_at:.4f},fps_change,{fps},{downgrade_to},2")
    if critical_at is not None:
        events.append(f"{critical_at:.2f},{critical_at:.4f},thermal,3,,")
    (path / "events.csv").write_text("\n".join(events) + "\n", encoding="utf-8")

    lines = [STATUS_HEADER]
    frames = 0
    size = 0
    current = fps
    for i in range(minutes * 6 + 1):
        elapsed = i * 10.0
        thermal = 0
        if serious_at is not None and elapsed >= serious_at:
            thermal = 2
            current = downgrade_to or fps
        if critical_at is not None and elapsed >= critical_at:
            thermal = 3
        delivered = 0.0 if i == 0 else current - 0.2
        frames += int(delivered * 10)
        size += 0 if i == 0 else current * 10_000 * 10  # 120fps で 1.2MB/秒
        charging = elapsed < charging_until
        battery = 1.0 - (0 if charging else (elapsed - charging_until) / 3600 * 0.30)
        lines.append(
            f"{elapsed:.2f},{elapsed:.4f},{thermal},0,{battery:.4f},{2 if charging else 1},{1 if dim else 0},"
            f"{0.0 if dim else 0.5:.2f},{current},{delivered:.2f},{frames},1,2,{size},{1.5:.2f}")
    if truncated_last_line:
        lines.append("3600.00,3600.0000,3,0,0.5")
    (path / "status.csv").write_text("\n".join(lines) + "\n", encoding="utf-8")

    if with_meta:
        (path / "meta.json").write_text(json.dumps({
            "device": "iPhone15,2", "requestedFrameRate": fps, "initialFrameRate": fps,
            "finalFrameRate": downgrade_to or fps, "format": f"1080x1920@{fps}", "formatNote": "",
            "fileBytes": size, "stopReason": "manual",
        }), encoding="utf-8")
    return path


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_thermal_times_and_verdict(self):
        path = make_session(self.root, "hot", minutes=60, fps=120, dim=False,
                            serious_at=1500, critical_at=3000, downgrade_to=60)
        s = summarize.load_session(path)
        self.assertEqual(summarize.first_reach(s, 2), 1500)
        self.assertEqual(summarize.first_reach(s, 3), 3000)
        self.assertEqual(summarize.max_thermal(s), 3)
        self.assertIn("NG 50.0分", summarize.critical_verdict(s))
        self.assertIn("降格済みでも到達", summarize.critical_verdict(s))

    def test_verdict_ok_and_too_short(self):
        ok = summarize.load_session(make_session(self.root, "ok", minutes=60, fps=60, dim=True))
        self.assertTrue(summarize.critical_verdict(ok).startswith("OK"))
        self.assertIsNone(summarize.first_reach(ok, 2))
        short = summarize.load_session(make_session(self.root, "short", minutes=20, fps=60, dim=True))
        self.assertTrue(summarize.critical_verdict(short).startswith("判定不可"))

    def test_battery_drain_per_hour(self):
        s = summarize.load_session(make_session(self.root, "b", minutes=30, fps=60, dim=False))
        drain = summarize.battery_drain(s)
        self.assertAlmostEqual(drain.per_hour, 30.0, places=1)
        self.assertAlmostEqual(drain.start, 100.0)
        self.assertFalse(drain.charged)

    def test_battery_drain_skips_charging_rows(self):
        s = summarize.load_session(make_session(self.root, "c", minutes=30, fps=60, dim=False, charging_until=600))
        drain = summarize.battery_drain(s)
        self.assertTrue(drain.charged)
        self.assertAlmostEqual(drain.per_hour, 30.0, places=1)

    def test_delivered_fps_split_by_setting(self):
        s = summarize.load_session(make_session(self.root, "d", minutes=10, fps=120, dim=False,
                                                serious_at=300, downgrade_to=60))
        delivered = summarize.delivered_by_setting(s)
        self.assertEqual(list(delivered), [120, 60])
        self.assertAlmostEqual(delivered[120][0], 119.8)
        self.assertAlmostEqual(delivered[60][1], 59.8)
        self.assertEqual(
            {fps: round(mb, 1) for fps, mb in summarize.size_rate_by_setting(s).items()}, {120: 72.0, 60: 36.0})
        changes = summarize.fps_changes(s)
        self.assertEqual(len(changes), 1)
        self.assertEqual(changes[0].values[:2], [120, 60])

    def test_file_size_per_minute(self):
        s = summarize.load_session(make_session(self.root, "f", minutes=10, fps=120, dim=False))
        rows = dict(summarize.summary_rows(s))
        self.assertEqual(rows["1分あたり"], "120: 72.0MB")
        self.assertEqual(rows["1クリップ（8秒）換算"], "120: 9.6MB")
        self.assertEqual(rows["落ちたフレーム"].split("（")[0], "3")

    def test_without_meta_and_truncated_line(self):
        path = make_session(self.root, "crash", minutes=5, fps=60, dim=True,
                            with_meta=False, truncated_last_line=True)
        s = summarize.load_session(path)
        self.assertEqual(len(s.rows), 31)
        rows = dict(summarize.summary_rows(s))
        self.assertEqual(rows["終了"], "記録途中で途切れた")
        self.assertEqual(rows["画面暗転"], "あり")
        self.assertEqual(rows["開始時fps"], "60")

    def test_dim_mixed(self):
        path = make_session(self.root, "m", minutes=1, fps=60, dim=False)
        status = path / "status.csv"
        lines = status.read_text(encoding="utf-8").splitlines()
        lines[1] = lines[1].replace(",1,0,0.50,", ",1,1,0.00,")
        status.write_text("\n".join(lines) + "\n", encoding="utf-8")
        s = summarize.load_session(path)
        self.assertTrue(summarize.dim_label(s).startswith("混在"))

    def test_main_prints_sessions_side_by_side(self):
        a = make_session(self.root, "s60", minutes=10, fps=60, dim=True)
        b = make_session(self.root, "s120", minutes=10, fps=120, dim=False, serious_at=300, downgrade_to=60)
        (self.root / "empty").mkdir()
        out = io.StringIO()
        with redirect_stdout(out):
            code = summarize.main([str(a), str(b), "--timeline", "5"])
        self.assertEqual(code, 0)
        text = out.getvalue()
        header = text.splitlines()[0]
        self.assertIn("s60", header)
        self.assertIn("s120", header)
        self.assertIn("5.0分 120→60（serious）", text)
        self.assertIn("[s120]", text)
        # 0分、5分、10分の3行
        timeline = text.split("[s60]")[1].split("[s120]")[0]
        self.assertEqual(sum(1 for line in timeline.splitlines() if "MB" in line), 3)

    def test_main_without_sessions(self):
        out = io.StringIO()
        with redirect_stdout(out), redirect_stderr(io.StringIO()):
            self.assertEqual(summarize.main([str(self.root / "missing")]), 1)


if __name__ == "__main__":
    unittest.main()
