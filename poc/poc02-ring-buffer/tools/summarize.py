"""POC-02 のセッションを集計する。

アプリが書いた clips.csv / chunks.csv / disk.csv / events.csv / meta.json / config.json を読み、
合否の判断に使う数字を出す。

    python summarize.py <セッションフォルダ>
    python summarize.py <セッションフォルダ> --max-latency 4 --short-tolerance 0.1

出すもの:
- インパクトから保存完了までの所要時間（全体、トリガの種類ごと）
- クリップのファイルサイズ
- ディスク使用量の最大値と、チャンクの循環削除が効いていたか
- 失敗（クリップ、チャンク、エラー、落ちたフレーム）
- クリップごとの、依頼した長さと実際の長さ
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
import sys
from dataclasses import dataclass, field
from pathlib import Path

MB = 1024 * 1024


# ---------------------------------------------------------------- 読み込み


@dataclass
class Clip:
    number: int
    source: str
    status: str
    impact_t: float
    latency_s: float
    detect_delay_s: float
    export_ms: float
    requested_start: float
    requested_end: float
    requested_s: float
    covered_s: float
    actual_s: float
    chunks: int
    gaps: int
    bytes: int
    error: str

    @property
    def ok(self) -> bool:
        return self.status == "ok"


@dataclass
class Session:
    path: Path
    config: dict
    meta: dict
    clips: list[Clip]
    chunks: list[dict]
    disk: list[dict]
    events: list[dict]


def _read_csv(path: Path) -> list[dict]:
    if not path.exists():
        return []
    with path.open(newline="", encoding="utf-8") as f:
        return list(csv.DictReader(f))


def _read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def _float(value: str | None, default: float = math.nan) -> float:
    try:
        return float(value) if value not in (None, "") else default
    except ValueError:
        return default


def _int(value: str | None, default: int = 0) -> int:
    try:
        return int(float(value)) if value not in (None, "") else default
    except ValueError:
        return default


def load_session(path: Path) -> Session:
    path = Path(path)
    if not (path / "clips.csv").exists():
        raise FileNotFoundError(f"clips.csv がありません: {path}")
    clips = [
        Clip(
            number=_int(row["clip"]),
            source=row["source"],
            status=row["status"],
            impact_t=_float(row["impact_t"]),
            latency_s=_float(row["latency_s"]),
            detect_delay_s=_float(row["detect_delay_s"]),
            export_ms=_float(row["export_ms"]),
            requested_start=_float(row["requested_start"]),
            requested_end=_float(row["requested_end"]),
            requested_s=_float(row["requested_s"]),
            covered_s=_float(row["covered_s"], 0.0),
            actual_s=_float(row["actual_s"], 0.0),
            chunks=_int(row["chunks"]),
            gaps=_int(row["gaps"]),
            bytes=_int(row["bytes"]),
            error=row.get("error") or "",
        )
        for row in _read_csv(path / "clips.csv")
    ]
    clips.sort(key=lambda c: c.number)
    return Session(
        path=path,
        config=_read_json(path / "config.json"),
        meta=_read_json(path / "meta.json"),
        clips=clips,
        chunks=_read_csv(path / "chunks.csv"),
        disk=_read_csv(path / "disk.csv"),
        events=_read_csv(path / "events.csv"),
    )


# ---------------------------------------------------------------- 集計


def describe(values: list[float]) -> dict | None:
    """件数・最小・中央値・90パーセンタイル（最近傍順位）・最大"""
    values = sorted(v for v in values if not math.isnan(v))
    if not values:
        return None
    p90 = values[max(0, math.ceil(0.9 * len(values)) - 1)]
    return {
        "n": len(values),
        "min": values[0],
        "median": statistics.median(values),
        "p90": p90,
        "max": values[-1],
        "mean": statistics.fmean(values),
    }


@dataclass
class Summary:
    clips_total: int = 0
    clips_ok: int = 0
    clips_failed: int = 0
    by_source: dict[str, int] = field(default_factory=dict)
    triggers: dict[str, int] = field(default_factory=dict)
    latency: dict | None = None
    latency_by_source: dict[str, dict | None] = field(default_factory=dict)
    detect_delay_hit: dict | None = None
    export_ms: dict | None = None
    over_latency: list[int] = field(default_factory=list)
    size_mb: dict | None = None
    short_clips: list[int] = field(default_factory=list)
    overlapping_pairs: int = 0
    max_chunk_files: int = 0
    max_chunk_mb: float = 0.0
    max_total_mb: float = 0.0
    final_clip_mb: float = 0.0
    min_free_mb: float | None = None
    clip_mb_per_hour: float | None = None
    retained_chunks: int | None = None
    chunk_events: dict[str, int] = field(default_factory=dict)
    failures: list[str] = field(default_factory=list)
    dropped_frames: int = 0
    standby_misses: int = 0
    duration_s: float = 0.0


def summarize(session: Session, max_latency: float = 5.0, short_tolerance: float = 0.05) -> Summary:
    s = Summary()
    clips = session.clips
    ok = [c for c in clips if c.ok]
    s.clips_total = len(clips)
    s.clips_ok = len(ok)
    s.clips_failed = len(clips) - len(ok)
    for c in clips:
        s.by_source[c.source] = s.by_source.get(c.source, 0) + 1

    # トリガの数（クリップの行が欠けていれば、ここと合わない）
    for e in session.events:
        kind = e.get("kind", "")
        if kind.startswith("trigger_"):
            source = kind[len("trigger_"):]
            s.triggers[source] = s.triggers.get(source, 0) + 1

    s.latency = describe([c.latency_s for c in ok])
    for source in sorted({c.source for c in ok}):
        s.latency_by_source[source] = describe([c.latency_s for c in ok if c.source == source])
    s.detect_delay_hit = describe([c.detect_delay_s for c in ok if c.source == "hit"])
    s.export_ms = describe([c.export_ms for c in ok])
    s.over_latency = [c.number for c in ok if c.latency_s > max_latency]
    s.size_mb = describe([c.bytes / MB for c in ok])
    s.short_clips = [c.number for c in ok if c.actual_s < c.requested_s - short_tolerance]

    # 依頼した範囲が前のクリップと重なる組（連続打撃、案A）
    ordered = sorted(clips, key=lambda c: c.requested_start)
    s.overlapping_pairs = sum(
        1 for a, b in zip(ordered, ordered[1:]) if b.requested_start < a.requested_end
    )

    for row in session.disk:
        chunk_bytes = _int(row.get("chunk_bytes"))
        clip_bytes = _int(row.get("clip_bytes"))
        s.max_chunk_files = max(s.max_chunk_files, _int(row.get("chunk_files")))
        s.max_chunk_mb = max(s.max_chunk_mb, chunk_bytes / MB)
        s.max_total_mb = max(s.max_total_mb, (chunk_bytes + clip_bytes) / MB)
        free = _int(row.get("free_bytes"), -1)
        if free >= 0:
            free_mb = free / MB
            s.min_free_mb = free_mb if s.min_free_mb is None else min(s.min_free_mb, free_mb)
    if session.disk:
        s.final_clip_mb = _int(session.disk[-1].get("clip_bytes")) / MB

    s.duration_s = float(session.meta.get("durationSeconds") or 0)
    if not s.duration_s and session.disk:
        s.duration_s = _float(session.disk[-1].get("t"), 0.0)
    total_clip_bytes = sum(c.bytes for c in ok)
    if s.duration_s > 0:
        s.clip_mb_per_hour = total_clip_bytes / MB / s.duration_s * 3600

    ring = session.config.get("ringBuffer", {})
    if "retainedChunks" in ring:
        s.retained_chunks = int(ring["retainedChunks"])

    for row in session.chunks:
        event = row.get("event", "")
        s.chunk_events[event] = s.chunk_events.get(event, 0) + 1
        if event in ("failed", "delete_failed"):
            s.failures.append(f"チャンク {row.get('index')} {event}: {row.get('note', '')}".rstrip(": "))

    for c in clips:
        if not c.ok:
            s.failures.append(f"クリップ {c.number}（{c.source}）失敗: {c.error}")
        elif c.gaps:
            s.failures.append(f"クリップ {c.number}（{c.source}）チャンクの抜け {c.gaps} か所")
    for e in session.events:
        kind = e.get("kind", "")
        if kind == "dropped_frame":
            s.dropped_frames += 1
        elif kind == "standby_miss":
            s.standby_misses += 1
        elif kind == "error" and not e.get("note", "").startswith("クリップ失敗"):
            # クリップの失敗は clips.csv 側で数えている
            s.failures.append(f"t={e.get('t')} エラー: {e.get('note', '')}")
    if session.meta.get("stopReason"):
        s.failures.append(f"計測の中断: {session.meta['stopReason']}")
    return s


# ---------------------------------------------------------------- 出力


def _fmt_stats(d: dict | None, unit: str, digits: int = 2) -> str:
    if d is None:
        return "（データなし）"
    f = f"{{:.{digits}f}}"
    return (
        f"n={d['n']}  最小 {f.format(d['min'])}{unit}  中央値 {f.format(d['median'])}{unit}  "
        f"p90 {f.format(d['p90'])}{unit}  最大 {f.format(d['max'])}{unit}"
    )


def format_report(session: Session, s: Summary, max_latency: float) -> str:
    lines: list[str] = []
    meta = session.meta
    lines.append(f"# {session.path.name}")
    if meta:
        lines.append(
            f"端末 {meta.get('device', '?')} / iOS {meta.get('systemVersion', '?')} / "
            f"{meta.get('videoFormat', '?')} / {s.duration_s / 60:.1f} 分"
        )
    ring = session.config.get("ringBuffer", {})
    if ring:
        lines.append(
            f"チャンク {ring.get('chunkSeconds')}秒 × 保持 {ring.get('retainedChunks')}個 / "
            f"切り出し 前{ring.get('clipBeforeSeconds')}秒＋後{ring.get('clipAfterSeconds')}秒"
        )
    lines.append("")

    lines.append("## クリップ")
    sources = "  ".join(f"{k} {v}" for k, v in sorted(s.by_source.items()))
    lines.append(f"保存 {s.clips_ok} / 失敗 {s.clips_failed} / 計 {s.clips_total}  （{sources}）")
    if s.triggers and sum(s.triggers.values()) != s.clips_total:
        lines.append(f"注意: トリガ数 {sum(s.triggers.values())} とクリップの行数 {s.clips_total} が合いません（欠落の疑い）")
    lines.append(f"依頼範囲が前のクリップと重なる組 {s.overlapping_pairs}")
    lines.append("")

    lines.append("## インパクトから保存完了までの所要時間")
    lines.append(f"全体      {_fmt_stats(s.latency, '秒')}")
    for source, d in s.latency_by_source.items():
        lines.append(f"{source:<9} {_fmt_stats(d, '秒')}")
    lines.append(f"実打判定の遅れ（hit） {_fmt_stats(s.detect_delay_hit, '秒')}")
    lines.append(f"連結と書き出し        {_fmt_stats(s.export_ms, 'ms', 0)}")
    over = ", ".join(map(str, s.over_latency)) or "なし"
    lines.append(f"{max_latency:g}秒を超えたクリップ: {over}")
    lines.append("")

    lines.append("## ファイルサイズ")
    lines.append(f"1クリップ {_fmt_stats(s.size_mb, 'MB')}")
    if s.clip_mb_per_hour is not None:
        lines.append(f"クリップの合計ペース {s.clip_mb_per_hour:.0f} MB/時")
    lines.append("")

    lines.append("## ディスク")
    retained = f"（保持の設定 {s.retained_chunks}個）" if s.retained_chunks is not None else ""
    lines.append(f"チャンクのファイル数 最大 {s.max_chunk_files}{retained}")
    if s.retained_chunks is not None and s.max_chunk_files > s.retained_chunks + 3:
        lines.append("注意: チャンクが保持数より大きく増えています。循環削除が追いついていない可能性があります")
    lines.append(f"チャンク 最大 {s.max_chunk_mb:.1f} MB / チャンク＋クリップ 最大 {s.max_total_mb:.1f} MB")
    lines.append(f"終了時のクリップ合計 {s.final_clip_mb:.1f} MB")
    if s.min_free_mb is not None:
        lines.append(f"空き容量 最小 {s.min_free_mb / 1024:.1f} GB")
    events = "  ".join(f"{k} {v}" for k, v in sorted(s.chunk_events.items()))
    lines.append(f"チャンクの記録: {events or 'なし'}")
    lines.append("")

    lines.append("## 失敗")
    lines.append(f"落ちたフレーム {s.dropped_frames} / 待機中のライタが間に合わなかった境界 {s.standby_misses}")
    if s.failures:
        lines.extend(f"- {f}" for f in s.failures)
    else:
        lines.append("なし")
    lines.append("")

    lines.append("## クリップごとの長さ（依頼 / チャンクで賄えた範囲 / 実際）")
    lines.append("clip  source    impact_t  依頼s  賄えたs  実際s    差s  所要s     MB  状態")
    for c in session.clips:
        diff = c.actual_s - c.requested_s
        mark = " 短い" if c.number in s.short_clips else ""
        lines.append(
            f"{c.number:>4}  {c.source:<8} {c.impact_t:>9.2f} {c.requested_s:>6.2f} {c.covered_s:>8.2f} "
            f"{c.actual_s:>6.2f} {diff:>6.2f} {c.latency_s:>6.2f} {c.bytes / MB:>6.1f}  {c.status}{mark}"
        )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="POC-02 のセッションを集計する")
    parser.add_argument("session", type=Path, help="sessions/<日時>/ のフォルダ")
    parser.add_argument("--max-latency", type=float, default=5.0,
                        help="インパクトから保存完了までの許容秒数（超えたクリップを列挙する）")
    parser.add_argument("--short-tolerance", type=float, default=0.05,
                        help="実際の長さが依頼よりこれ以上短ければ「短い」とする（秒）")
    args = parser.parse_args(argv)

    try:
        session = load_session(args.session)
    except FileNotFoundError as e:
        print(e, file=sys.stderr)
        return 1
    summary = summarize(session, max_latency=args.max_latency, short_tolerance=args.short_tolerance)
    print(format_report(session, summary, args.max_latency))
    return 0


if __name__ == "__main__":
    sys.exit(main())
