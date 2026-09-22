"""POC-03 のセッションを集計し、横に並べて比べる。

60fps と 120fps、画面暗転の有無、端末の違いを並べて見るためのもの。

    python summarize.py <セッションフォルダ> [<セッションフォルダ> ...]
    python summarize.py sessions/*                      # まとめて並べる
    python summarize.py <セッションフォルダ> --timeline 5   # 5分ごとの発熱・電池・fps の推移も出す

セッションフォルダには status.csv が必要。meta.json が無い（アプリが途中で落ちた）場合も、
status.csv と events.csv から分かる範囲で集計する。
"""

from __future__ import annotations

import argparse
import csv
import json
import statistics
import sys
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

THERMAL_NAMES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
PRESSURE_NAMES = {0: "nominal", 1: "fair", 2: "serious", 3: "critical", 4: "shutdown"}
# meta.json の stopReason。running のまま残っているのはアプリが途中で落ちた時
STOP_NAMES = {
    "manual": "手動",
    "session_limit": "上限の時間",
    "writer_failed": "書き出し失敗",
    "running": "記録途中で途切れた",
    None: "記録途中で途切れた",
}
# UIDevice.BatteryState
UNPLUGGED = 1
# 合否基準の稼働時間（分）
PASS_MINUTES = 60.0
# クリップ1本の長さ（秒）。CLAUDE.md の暫定値（前5秒＋後3秒）
CLIP_SECONDS = 8.0


# ---------------------------------------------------------------- 読み込み


@dataclass
class Row:
    elapsed: float
    t: float
    thermal: int
    pressure: int
    battery: float
    battery_state: int
    dim: bool
    fps_setting: int
    fps_delivered: float
    frames: int
    dropped_capture: int
    dropped_writer: int
    file_bytes: int
    motion_ms: float


@dataclass
class Event:
    elapsed: float
    t: float
    kind: str
    values: list


@dataclass
class Session:
    path: Path
    config: dict
    meta: dict
    rows: list
    events: list = field(default_factory=list)

    @property
    def name(self) -> str:
        return self.path.name


def _float(text: str, default: float = 0.0) -> float:
    try:
        return float(text)
    except (TypeError, ValueError):
        return default


def _read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def load_session(path: Path) -> Session:
    status = path / "status.csv"
    if not status.exists():
        raise FileNotFoundError(f"{status} がありません")

    rows = []
    with status.open(encoding="utf-8", newline="") as f:
        for r in csv.DictReader(f):
            # アプリが落ちると最後の行が途中で切れていることがある
            if r.get("motion_ms") in (None, ""):
                continue
            rows.append(Row(
                elapsed=_float(r["elapsed_s"]),
                t=_float(r["t"]),
                thermal=int(_float(r["thermal"])),
                pressure=int(_float(r["pressure"])),
                battery=_float(r["battery"], -1),
                battery_state=int(_float(r["battery_state"])),
                dim=r["dim"] == "1",
                fps_setting=int(_float(r["fps_setting"])),
                fps_delivered=_float(r["fps_delivered"]),
                frames=int(_float(r["frames"])),
                dropped_capture=int(_float(r["dropped_capture"])),
                dropped_writer=int(_float(r["dropped_writer"])),
                file_bytes=int(_float(r["file_bytes"])),
                motion_ms=_float(r["motion_ms"], -1),
            ))
    rows.sort(key=lambda row: row.elapsed)

    events = []
    events_path = path / "events.csv"
    if events_path.exists():
        with events_path.open(encoding="utf-8", newline="") as f:
            for r in csv.DictReader(f):
                if not r.get("kind"):
                    continue
                values = [_float(r.get(k) or "", float("nan")) for k in ("v1", "v2", "v3")]
                events.append(Event(_float(r["elapsed_s"]), _float(r["t"]), r["kind"], values))
    events.sort(key=lambda e: e.elapsed)

    return Session(
        path=path,
        config=_read_json(path / "config.json"),
        meta=_read_json(path / "meta.json"),
        rows=rows,
        events=events,
    )


# ---------------------------------------------------------------- 集計


def duration_seconds(s: Session) -> float:
    candidates = [r.elapsed for r in s.rows] + [e.elapsed for e in s.events]
    return max(candidates, default=0.0)


def first_reach(s: Session, level: int) -> float | None:
    """発熱状態が level 以上になった最初の経過秒。thermal イベントと status.csv の両方から探す"""
    times = [e.elapsed for e in s.events if e.kind == "thermal" and e.values[0] >= level]
    times += [r.elapsed for r in s.rows if r.thermal >= level]
    return min(times, default=None)


def max_thermal(s: Session) -> int:
    states = [r.thermal for r in s.rows]
    states += [int(e.values[0]) for e in s.events if e.kind == "thermal"]
    return max(states, default=-1)


def max_pressure(s: Session) -> int:
    levels = [r.pressure for r in s.rows]
    levels += [int(e.values[0]) for e in s.events if e.kind == "pressure" and e.values[0] == e.values[0]]
    return max(levels, default=-1)


@dataclass
class BatteryDrain:
    start: float | None
    end: float | None
    per_hour: float | None
    charged: bool


def battery_drain(s: Session) -> BatteryDrain:
    """電源につないでいない行だけで、1時間あたりの減り（%）を出す"""
    known = [r for r in s.rows if r.battery >= 0]
    charged = any(r.battery_state != UNPLUGGED for r in known)
    unplugged = [r for r in known if r.battery_state == UNPLUGGED]
    start = known[0].battery * 100 if known else None
    end = known[-1].battery * 100 if known else None
    per_hour = None
    if len(unplugged) >= 2:
        hours = (unplugged[-1].elapsed - unplugged[0].elapsed) / 3600
        if hours > 0:
            per_hour = (unplugged[0].battery - unplugged[-1].battery) * 100 / hours
    return BatteryDrain(start, end, per_hour, charged)


def delivered_by_setting(s: Session) -> dict:
    """fps の設定ごとの実測 fps（平均、最小）。最初の行は開始直後の立ち上がりを含むので除く"""
    groups: dict = {}
    for r in s.rows[1:]:
        # 設定を変えた直後の行は、変更前と変更後が混ざる
        groups.setdefault(r.fps_setting, []).append(r.fps_delivered)
    return {fps: (statistics.fmean(v), min(v)) for fps, v in sorted(groups.items(), reverse=True)}


def size_rate_by_setting(s: Session) -> dict:
    """fps の設定ごとの 1分あたりのファイルの増え方（MB）。降格の前後で混ざらないよう行の差分で出す"""
    grown: dict = {}
    for prev, cur in zip(s.rows, s.rows[1:]):
        span = cur.elapsed - prev.elapsed
        if span <= 0 or cur.file_bytes < prev.file_bytes:
            continue
        total = grown.setdefault(cur.fps_setting, [0, 0.0])
        total[0] += cur.file_bytes - prev.file_bytes
        total[1] += span
    return {fps: b / 1_000_000 / (sec / 60) for fps, (b, sec) in sorted(grown.items(), reverse=True) if sec > 0}


def fps_changes(s: Session) -> list:
    return [e for e in s.events if e.kind in ("fps_change", "fps_change_failed")]


def dim_label(s: Session) -> str:
    if not s.rows:
        return "?"
    on = sum(1 for r in s.rows if r.dim)
    if on == 0:
        return "なし"
    if on == len(s.rows):
        return "あり"
    return f"混在（{on * 100 // len(s.rows)}%）"


def file_bytes(s: Session) -> int:
    from_rows = max((r.file_bytes for r in s.rows), default=0)
    return max(int(s.meta.get("fileBytes") or 0), from_rows)


def critical_verdict(s: Session) -> str:
    """合否基準：60分の稼働で .critical に達しないこと"""
    critical = first_reach(s, 3)
    minutes = duration_seconds(s) / 60
    if critical is not None and critical / 60 <= PASS_MINUTES:
        downgraded = any(e.kind == "fps_change" and e.elapsed <= critical for e in s.events)
        note = "（降格済みでも到達）" if downgraded else ""
        return f"NG {critical / 60:.1f}分で到達{note}"
    if minutes < PASS_MINUTES:
        return f"判定不可（{minutes:.0f}分しかない）"
    return f"OK（{PASS_MINUTES:.0f}分以内は未到達）"


# ---------------------------------------------------------------- 表示


def fmt_minutes(seconds: float | None) -> str:
    return "未到達" if seconds is None else f"{seconds / 60:.1f}分"


def fmt_opt(value, spec: str, suffix: str = "") -> str:
    return "?" if value is None else f"{value:{spec}}{suffix}"


def summary_rows(s: Session) -> list:
    """(項目名, 値) の並び。表の1列ぶん"""
    cfg, meta = s.config, s.meta
    minutes = duration_seconds(s) / 60
    drain = battery_drain(s)
    total_frames = s.rows[-1].frames if s.rows else int(meta.get("videoFrames") or 0)
    dropped_capture = s.rows[-1].dropped_capture if s.rows else 0
    dropped_writer = s.rows[-1].dropped_writer if s.rows else 0
    dropped = dropped_capture + dropped_writer
    size_mb = file_bytes(s) / 1_000_000
    size_rates = size_rate_by_setting(s)
    motion = [r.motion_ms for r in s.rows[1:] if r.motion_ms >= 0]

    delivered = delivered_by_setting(s)
    delivered_text = " / ".join(f"{fps}: 平均{mean:.1f} 最小{low:.1f}" for fps, (mean, low) in delivered.items())

    changes = fps_changes(s)
    change_text = "なし"
    if changes:
        parts = []
        for e in changes:
            thermal = THERMAL_NAMES.get(int(e.values[2]), "?") if e.values[2] == e.values[2] else "?"
            if e.kind == "fps_change":
                parts.append(f"{e.elapsed / 60:.1f}分 {int(e.values[0])}→{int(e.values[1])}（{thermal}）")
            else:
                parts.append(f"{e.elapsed / 60:.1f}分 {int(e.values[0])}へ失敗（{thermal}）")
        change_text = "、".join(parts)

    battery_text = f"{fmt_opt(drain.start, '.0f', '%')} → {fmt_opt(drain.end, '.0f', '%')}"
    drain_text = fmt_opt(drain.per_hour, ".1f", "%/時")
    if drain.charged:
        drain_text += "（充電中の区間あり。除いて計算）"

    requested = cfg.get("frameRate", meta.get("requestedFrameRate", "?"))
    initial = meta.get("initialFrameRate") or (s.rows[0].fps_setting if s.rows else "?")
    fmt = meta.get("format", "?")
    if meta.get("formatNote"):
        fmt += f"（{meta['formatNote']}）"

    return [
        ("端末", meta.get("device", "?")),
        ("希望fps", str(requested)),
        ("開始時fps", str(initial)),
        ("フォーマット", fmt),
        ("画面暗転", dim_label(s)),
        ("動き検出", {True: "あり", False: "なし"}.get(cfg.get("motionMeterEnabled"), "?")),
        ("稼働時間", f"{minutes:.1f}分"),
        ("終了", STOP_NAMES.get(meta.get("stopReason"), str(meta.get("stopReason")))),
        (".fair 到達", fmt_minutes(first_reach(s, 1))),
        (".serious 到達", fmt_minutes(first_reach(s, 2))),
        (".critical 到達", fmt_minutes(first_reach(s, 3))),
        ("最高の発熱状態", THERMAL_NAMES.get(max_thermal(s), "?")),
        ("カメラの負荷（最高）", PRESSURE_NAMES.get(max_pressure(s), "?")),
        (f"{PASS_MINUTES:.0f}分で.critical", critical_verdict(s)),
        ("電池", battery_text),
        ("電池の減り", drain_text),
        ("実測fps（設定ごと）", delivered_text or "?"),
        ("落ちたフレーム", f"{dropped}（取得{dropped_capture} 書出{dropped_writer}）"
            + (f" {dropped * 100 / (total_frames + dropped_capture):.2f}%" if total_frames + dropped_capture else "")),
        ("ファイルサイズ", f"{size_mb:.0f}MB"),
        ("1分あたり", " / ".join(f"{fps}: {mb:.1f}MB" for fps, mb in size_rates.items()) or "?"),
        (f"1クリップ（{CLIP_SECONDS:.0f}秒）換算", " / ".join(
            f"{fps}: {mb * CLIP_SECONDS / 60:.1f}MB" for fps, mb in size_rates.items()) or "?"),
        ("動き検出の処理", f"{statistics.fmean(motion):.2f}ms/フレーム" if motion else "-"),
        ("fps降格", change_text),
    ]


def display_width(text: str) -> int:
    return sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in text)


def pad(text: str, width: int) -> str:
    return text + " " * (width - display_width(text))


def format_table(sessions: list) -> str:
    columns = [summary_rows(s) for s in sessions]
    labels = [label for label, _ in columns[0]]
    header = ["", *[s.name for s in sessions]]
    table = [header] + [[label, *[col[i][1] for col in columns]] for i, label in enumerate(labels)]
    widths = [max(display_width(row[c]) for row in table) for c in range(len(header))]
    lines = []
    for n, row in enumerate(table):
        lines.append("  ".join(pad(cell, widths[c]) for c, cell in enumerate(row)).rstrip())
        if n == 0:
            lines.append("  ".join("-" * w for w in widths))
    return "\n".join(lines)


def format_timeline(s: Session, step_minutes: float) -> str:
    """step_minutes ごとに、その時点までの最後の行を出す"""
    lines = [f"[{s.name}]", "     経過  発熱      カメラ    電池  設定fps  実測fps  ファイル"]
    step = step_minutes * 60
    next_at = 0.0
    for i, r in enumerate(s.rows):
        is_last = i == len(s.rows) - 1
        if r.elapsed + 1e-9 < next_at and not is_last:
            continue
        battery = f"{r.battery * 100:.0f}%" if r.battery >= 0 else "?"
        lines.append(
            f"  {r.elapsed / 60:5.1f}分  {THERMAL_NAMES.get(r.thermal, '?'):8}  "
            f"{PRESSURE_NAMES.get(r.pressure, '?'):8}  {battery:>4}  {r.fps_setting:7d}  "
            f"{r.fps_delivered:7.1f}  {r.file_bytes / 1_000_000:6.0f}MB")
        while next_at <= r.elapsed:
            next_at += step
    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="POC-03 のセッションを集計して並べる")
    parser.add_argument("sessions", type=Path, nargs="+", help="セッションフォルダ（status.csv がある場所）")
    parser.add_argument("--timeline", type=float, metavar="分", help="この間隔で発熱・電池・fps の推移も出す")
    args = parser.parse_args(argv)

    sessions = []
    for path in args.sessions:
        if not path.is_dir():
            continue
        try:
            sessions.append(load_session(path))
        except FileNotFoundError as e:
            print(f"スキップ: {e}", file=sys.stderr)
    if not sessions:
        print("集計できるセッションがありません", file=sys.stderr)
        return 1

    print(format_table(sessions))
    if args.timeline:
        for s in sessions:
            print()
            print(format_timeline(s, args.timeline))
    return 0


if __name__ == "__main__":
    sys.exit(main())
