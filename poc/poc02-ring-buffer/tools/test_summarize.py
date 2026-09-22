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

MB = 1024 * 1024

CONFIG = {
    "ringBuffer": {
        "frameRate": 60,
        "videoBitRate": 8000000,
        "maxKeyFrameIntervalFrames": 30,
        "chunkSeconds": 1.0,
        "retainedChunks": 10,
        "clipBeforeSeconds": 5,
        "clipAfterSeconds": 3,
        "intervalTriggerSeconds": 4,
        "audioCloseGraceSeconds": 0.5,
        "diskLogIntervalSeconds": 1,
        "keepChunksAtEnd": False,
    },
    "detection": {"audioDebounceSeconds": 0.5},
}

META = {
    "device": "iPhone16,1",
    "systemVersion": "18.0",
    "videoFormat": "1080x1920@60",
    "durationSeconds": 600.0,
    "stopReason": None,
}

CLIP_HEADER = (
    "clip,source,status,impact_t,trigger_t,buffered_t,done_t,latency_s,detect_delay_s,export_ms,"
    "requested_start,requested_end,requested_s,covered_start,covered_end,covered_s,actual_s,"
    "chunks,gaps,bytes,error"
)


def clip_row(number, source, impact, latency, actual=8.0, covered=8.0, status="ok",
             bytes_=8 * MB, gaps=0, error="", detect_delay=0.0, export_ms=300.0):
    start, end = impact - 5, impact + 3
    trigger = impact + detect_delay
    done = impact + latency
    return ",".join(str(v) for v in [
        number, source, status, impact, trigger, impact + 3.2, done, latency, detect_delay, export_ms,
        start, end, 8.0, start, start + covered, covered, actual, 9, gaps, bytes_, error,
    ])


class SummarizeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name) / "20260923-101500"
        self.dir.mkdir()
        (self.dir / "config.json").write_text(json.dumps(CONFIG), encoding="utf-8")
        (self.dir / "meta.json").write_text(json.dumps(META), encoding="utf-8")

        clips = [
            CLIP_HEADER,
            clip_row(1, "hit", 20.0, 3.6, detect_delay=0.4),
            clip_row(2, "hit", 60.0, 3.8, detect_delay=0.6),
            # 4秒後の連打（前のクリップと4秒重なる）
            clip_row(3, "interval", 64.0, 3.4),
            clip_row(4, "manual", 100.0, 6.5),  # 遅い
            # 計測開始直後で前5秒が足りない
            clip_row(5, "manual", 2.0, 3.5, actual=5.0, covered=5.0),
            clip_row(6, "hit", 200.0, 3.2, status="failed", bytes_=0, actual=0.0,
                     error="チャンクに映像がありません"),
            clip_row(7, "interval", 300.0, 3.3, gaps=1),
        ]
        (self.dir / "clips.csv").write_text("\n".join(clips) + "\n", encoding="utf-8")

        chunks = ["t,event,index,start_t,end_t,frames,bytes,finish_ms,note"]
        for i in range(12):
            chunks.append(f"{i + 1.1},finalized,{i},{i},{i + 1},60,{MB},12.5,")
        chunks.append("12.1,deleted,0,0,1,60,1048576,,")
        chunks.append("12.2,failed,12,12,13,60,0,5.0,encoder error")
        (self.dir / "chunks.csv").write_text("\n".join(chunks) + "\n", encoding="utf-8")

        disk = ["t,chunk_files,chunk_bytes,clip_files,clip_bytes,free_bytes"]
        disk.append(f"1.0,2,{2 * MB},0,0,{50 * 1024 * MB}")
        disk.append(f"2.0,11,{11 * MB},1,{8 * MB},{49 * 1024 * MB}")
        disk.append(f"3.0,10,{10 * MB},6,{48 * MB},{48 * 1024 * MB}")
        (self.dir / "disk.csv").write_text("\n".join(disk) + "\n", encoding="utf-8")

        events = [
            "t,kind,v1,v2,v3,note",
            "0.0000,thermal,0,,,",
            "20.4,trigger_hit,1,20.0,,",
            "60.6,trigger_hit,2,60.0,,",
            "64.0,trigger_interval,3,64.0,,",
            "100.0,trigger_manual,4,100.0,,",
            "2.0,trigger_manual,5,2.0,,",
            "200.0,trigger_hit,6,200.0,,",
            "300.0,trigger_interval,7,300.0,,",
            "301.0,trigger_interval,8,301.0,,",  # クリップの行がない（欠落）
            "50.0,dropped_frame,1,,,",
            "51.0,dropped_frame,0,,,",
            "70.0,standby_miss,15,32.1,,",
            "203.2,error,6,,,クリップ失敗 チャンクに映像がありません",
            "250.0,error,,,,待機中のライタを作れません",
        ]
        (self.dir / "events.csv").write_text("\n".join(events) + "\n", encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def summary(self, **kwargs):
        return summarize.summarize(summarize.load_session(self.dir), **kwargs)

    def test_counts(self):
        s = self.summary()
        self.assertEqual(s.clips_total, 7)
        self.assertEqual(s.clips_ok, 6)
        self.assertEqual(s.clips_failed, 1)
        self.assertEqual(s.by_source, {"hit": 3, "interval": 2, "manual": 2})
        self.assertEqual(s.triggers, {"hit": 3, "interval": 3, "manual": 2})

    def test_latency(self):
        s = self.summary()
        self.assertEqual(s.latency["n"], 6)
        self.assertAlmostEqual(s.latency["min"], 3.3)
        self.assertAlmostEqual(s.latency["max"], 6.5)
        self.assertAlmostEqual(s.latency["median"], 3.55)
        self.assertAlmostEqual(s.latency["p90"], 6.5)
        self.assertEqual(s.over_latency, [4])
        self.assertEqual(self.summary(max_latency=3.5).over_latency, [1, 2, 4])
        self.assertAlmostEqual(s.latency_by_source["hit"]["median"], 3.7)
        self.assertAlmostEqual(s.detect_delay_hit["max"], 0.6)

    def test_sizes_and_disk(self):
        s = self.summary()
        self.assertAlmostEqual(s.size_mb["median"], 8.0)
        self.assertEqual(s.max_chunk_files, 11)
        self.assertAlmostEqual(s.max_chunk_mb, 11.0)
        self.assertAlmostEqual(s.max_total_mb, 58.0)
        self.assertAlmostEqual(s.final_clip_mb, 48.0)
        self.assertAlmostEqual(s.min_free_mb, 48 * 1024)
        self.assertEqual(s.retained_chunks, 10)
        # 6本 × 8MB を 10分で → 1時間あたり 288MB
        self.assertAlmostEqual(s.clip_mb_per_hour, 288.0)
        self.assertEqual(s.chunk_events, {"finalized": 12, "deleted": 1, "failed": 1})

    def test_requested_vs_actual(self):
        s = self.summary()
        self.assertEqual(s.short_clips, [5])
        self.assertEqual(s.overlapping_pairs, 1)

    def test_failures(self):
        s = self.summary()
        self.assertEqual(s.dropped_frames, 2)
        self.assertEqual(s.standby_misses, 1)
        text = "\n".join(s.failures)
        self.assertIn("クリップ 6（hit）失敗", text)
        self.assertIn("クリップ 7（interval）チャンクの抜け 1", text)
        self.assertIn("チャンク 12 failed: encoder error", text)
        self.assertIn("待機中のライタを作れません", text)
        # クリップの失敗は events 側から二重に数えない
        self.assertEqual(text.count("チャンクに映像がありません"), 1)

    def test_report(self):
        out = io.StringIO()
        with redirect_stdout(out):
            code = summarize.main([str(self.dir), "--max-latency", "5"])
        self.assertEqual(code, 0)
        text = out.getvalue()
        self.assertIn("保存 6 / 失敗 1 / 計 7", text)
        self.assertIn("トリガ数 8 とクリップの行数 7 が合いません", text)
        self.assertIn("5秒を超えたクリップ: 4", text)
        self.assertIn(" 短い", text)
        self.assertIn("チャンクのファイル数 最大 11（保持の設定 10個）", text)

    def test_empty_session(self):
        empty = Path(self.tmp.name) / "empty"
        empty.mkdir()
        (empty / "clips.csv").write_text(CLIP_HEADER + "\n", encoding="utf-8")
        s = summarize.summarize(summarize.load_session(empty))
        self.assertEqual(s.clips_total, 0)
        self.assertIsNone(s.latency)
        out = io.StringIO()
        with redirect_stdout(out):
            self.assertEqual(summarize.main([str(empty)]), 0)
        self.assertIn("（データなし）", out.getvalue())

    def test_missing_folder(self):
        err = io.StringIO()
        with redirect_stderr(err):
            self.assertEqual(summarize.main([str(Path(self.tmp.name) / "none")]), 1)
        self.assertIn("clips.csv がありません", err.getvalue())


if __name__ == "__main__":
    unittest.main()
