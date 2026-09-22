"""Swift 側（HitDetector.swift）と replay.py の判定が一致するかを確かめるフィクスチャを作る。

test_replay.Scenario で合成ログを書き、replay.py で読み直して判定した結果を期待値として JSON に残す。
Swift のテスト（Tests/HitDetectionCoreTests/FixtureTests.swift）が同じ入力を時刻順に HitDetector へ流し、結果を突き合わせる。

    cd poc/poc01-hit-detection/tools
    python make_fixture.py

判定ロジックや Scenario を変えたら作り直すこと。
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

import replay
import test_replay
from test_replay import Scenario

OUT_DIR = Path(__file__).resolve().parent.parent / "Tests" / "HitDetectionCoreTests" / "Fixtures"

# ファイルを小さく保つため、セルの分割を粗くし、長さも短くする。
# 6×8 の既定の分割は Swift 側の HitDetectorTests で確かめている。
SMALL_GRID = {"motionGridCols": 2, "motionGridRows": 2}


def fixtures():
    """(名前, 説明, Scenario, 長さ秒, 設定の上書き, 動きの行を書き換える関数)"""
    yield ("01_own_hit", "自分の実打1球", Scenario().swing(1.0), 5.0, {}, None)
    yield (
        "02_mixed",
        "実打（2つ目のピークあり）・素振り・隣の打席・ワッグル中の隣の打球音",
        Scenario()
        .swing(0.5, second_peak_after=0.15)
        .motion(3.5, 5.5, 0.3)
        .impact(6.5)
        .motion(8.0, 8.3, 0.1)
        .impact(8.1),
        9.5,
        {},
        None,
    )
    yield (
        "03_louder_in_window",
        "時間窓に2つの音。大きい方をインパクトとする",
        Scenario().motion(1.0, 3.0, 0.3).impact(1.4, level=-30).impact(2.2, level=-5),
        4.5,
        {},
        None,
    )
    yield (
        "04_outside_window",
        "時間窓の外の音は使わない",
        Scenario().motion(1.0, 3.0, 0.3).impact(4.0),
        5.0,
        {},
        None,
    )
    yield (
        "05_outside_window_widened",
        "04 と同じ入力で、時間窓を広げると実打になる",
        Scenario().motion(1.0, 3.0, 0.3).impact(4.0),
        5.0,
        {"windowAfterEndSeconds": 1.2},
        None,
    )
    yield (
        "06_back_to_back",
        "間隔の短い3球",
        Scenario().swing(0.5, impact_after=1.0, length=1.5).swing(2.6, impact_after=1.0, length=1.5)
        .swing(4.7, impact_after=1.0, length=1.5),
        7.0,
        {"audioDebounceSeconds": 0.3},
        None,
    )
    yield (
        "07_open_at_stop",
        "計測終了の時点で動きの区間が閉じていない",
        Scenario().motion(3.0, 10.0, 0.3).impact(4.0),
        5.0,
        {},
        None,
    )
    yield (
        "08_too_long",
        "長すぎる動き（maxSwingSeconds 超え）はスイング候補にしない",
        Scenario().motion(0.5, 5.0, 0.3).impact(2.0),
        6.0,
        {"maxSwingSeconds": 3.0},
        None,
    )
    yield (
        "09_roi_columns",
        "3×4 セル。ROI 外の左の列だけずっと動いていても、ROI 内のセルだけで判定する",
        Scenario().swing(1.0),
        5.0,
        {"motionGridCols": 3, "motionGridRows": 4, "roi": [0.4, 0.0, 1.0, 1.0]},
        noisy_left_column,
    )


def noisy_left_column(cfg: dict, cells: list) -> list:
    cols = cfg["motionGridCols"]
    return [0.5 if i % cols == 0 else v for i, v in enumerate(cells)]


def build(name, description, scenario, duration, overrides, rewrite):
    config = dict(test_replay.CONFIG, **SMALL_GRID)
    config.update(overrides)

    # Scenario.write はモジュールの CONFIG と DURATION を見るので、一時的に差し替える
    saved = test_replay.CONFIG, test_replay.DURATION
    test_replay.CONFIG, test_replay.DURATION = config, duration
    try:
        with tempfile.TemporaryDirectory() as tmp:
            scenario.write(Path(tmp))
            session = replay.load_session(Path(tmp))
    finally:
        test_replay.CONFIG, test_replay.DURATION = saved

    if rewrite:
        session.motion_cells = [rewrite(config, row) for row in session.motion_cells]
        session._roi_cache.clear()

    r = replay.run(session, config)
    return {
        "name": name,
        "description": description,
        "config": config,
        # t, peak_db, hp_peak_db
        "audio": [list(block) for block in session.audio],
        # t, c0, c1, ...
        "motion": [[t] + row for t, row in zip(session.motion_t, session.motion_cells)],
        "expected": {
            # t, level
            "peaks": [[p.t, p.level] for p in r.peaks],
            # start, end, peak, スイング候補なら1
            "segments": [
                [s.start, s.end, s.peak, 1 if replay.is_swing_candidate(s, config) else 0] for s in r.segments
            ],
            # インパクト音の t, level, 区間の start, end
            "hits": [[h.impact.t, h.impact.level, h.segment.start, h.segment.end] for h in r.hits],
        },
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for old in OUT_DIR.glob("*.json"):
        old.unlink()
    total = 0
    for args in fixtures():
        fixture = build(*args)
        path = OUT_DIR / f"{fixture['name']}.json"
        text = json.dumps(fixture, ensure_ascii=False, separators=(",", ":"))
        path.write_text(text + "\n", encoding="utf-8")
        total += path.stat().st_size
        e = fixture["expected"]
        print(f"{path.name}: 音のピーク {len(e['peaks'])} / 区間 {len(e['segments'])} / 実打 {len(e['hits'])}"
              f"  {path.stat().st_size // 1024} KB")
    print(f"合計 {total // 1024} KB")
    return 0


if __name__ == "__main__":
    sys.exit(main())
