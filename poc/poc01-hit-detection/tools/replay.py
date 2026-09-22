"""POC-01 のログを再解析する。

アプリ（POC01/HitDetector.swift）と同じ判定ロジックを、閾値や時間窓を変えながらログに当て直す。
正解ラベル（labels.csv）があれば、ケースごとの保存率と合否を出す。

    python replay.py <セッションフォルダ>                     # 判定結果の一覧
    python replay.py <セッションフォルダ> --labels labels.csv   # 採点と、取りこぼしの理由
    python replay.py <セッションフォルダ> --labels labels.csv \
        --set audioRelativeThresholdDb=15,20,25 --set motionOnThreshold=0.05,0.08   # 組み合わせを総当たり

ロジックを変えたら HitDetector.swift も合わせること。
"""

from __future__ import annotations

import argparse
import csv
import itertools
import json
import math
import statistics
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

# 再解析で変えられるキー（DetectionConfig.swift の「再解析で変えられる」側）
TUNABLE = {
    "useHighPass": "bool",
    "audioRelativeThresholdDb": "float",
    "audioAbsoluteMinDb": "float",
    "audioFloorTauSeconds": "float",
    "audioDebounceSeconds": "float",
    "roi": "roi",
    "motionOnThreshold": "float",
    "motionOffThreshold": "float",
    "motionOffHoldSeconds": "float",
    "minSwingSeconds": "float",
    "maxSwingSeconds": "float",
    "minSwingPeak": "float",
    "windowBeforeStartSeconds": "float",
    "windowAfterEndSeconds": "float",
}

LABEL_KINDS = ("hit", "practice", "neighbor", "waggle", "address", "other")
# 音で時刻を決めるラベルと、動きで大まかに時刻を決めるラベル
SOUND_KINDS = ("hit", "neighbor")


# ---------------------------------------------------------------- データ


@dataclass
class AudioPeak:
    t: float
    level: float


@dataclass
class Segment:
    start: float
    end: float
    peak: float

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass
class Hit:
    impact: AudioPeak
    segment: Segment

    @property
    def t(self) -> float:
        return self.impact.t


@dataclass
class Label:
    t: float
    kind: str
    note: str = ""


@dataclass
class Session:
    path: Path
    config: dict
    audio: list  # (t, peak_db, hp_peak_db)
    motion_t: list  # t
    motion_cells: list  # [cell ratio, ...]
    app_hits: list  # t
    _roi_cache: dict = field(default_factory=dict)

    def roi_ratios(self, cfg: dict) -> list:
        cells = tuple(roi_cells(cfg))
        if cells not in self._roi_cache:
            n = len(cells)
            self._roi_cache[cells] = [
                (sum(row[i] for i in cells) / n) if n else 0.0 for row in self.motion_cells
            ]
        return self._roi_cache[cells]


# ---------------------------------------------------------------- 判定（HitDetector.swift と同じ）


def roi_cells(cfg: dict) -> list:
    cols, rows = cfg["motionGridCols"], cfg["motionGridRows"]
    x0, y0, x1, y1 = cfg["roi"]
    cells = []
    for r in range(rows):
        for c in range(cols):
            cx = (c + 0.5) / cols
            cy = (r + 0.5) / rows
            if x0 <= cx <= x1 and y0 <= cy <= y1:
                cells.append(r * cols + c)
    return cells


def audio_level(block, cfg) -> float:
    _, peak_db, hp_peak_db = block
    return hp_peak_db if cfg["useHighPass"] else peak_db


def detect_audio_peaks(audio: list, cfg: dict) -> list:
    peaks = []
    floor = None
    last = -math.inf
    alpha = min(1.0, cfg["audioBlockSeconds"] / cfg["audioFloorTauSeconds"])
    for block in audio:
        t = block[0]
        level = audio_level(block, cfg)
        if floor is None:
            floor = level
        threshold = floor + cfg["audioRelativeThresholdDb"]
        above = level >= threshold and level >= cfg["audioAbsoluteMinDb"]
        fire = above and t - last >= cfg["audioDebounceSeconds"]
        if level < threshold:
            floor = floor + alpha * (level - floor)
        if fire:
            last = t
            peaks.append(AudioPeak(t, level))
    return peaks


def audio_onsets(audio: list, cfg: dict, merge_seconds: float = 0.03) -> list:
    """デバウンスをかけない立ち上がり時刻。1ショットあたりのピーク数を数えるのに使う。"""
    onsets = []
    floor = None
    was_above = False
    alpha = min(1.0, cfg["audioBlockSeconds"] / cfg["audioFloorTauSeconds"])
    for block in audio:
        t = block[0]
        level = audio_level(block, cfg)
        if floor is None:
            floor = level
        threshold = floor + cfg["audioRelativeThresholdDb"]
        above = level >= threshold and level >= cfg["audioAbsoluteMinDb"]
        if above and not was_above and (not onsets or t - onsets[-1] > merge_seconds):
            onsets.append(t)
        was_above = above
        if level < threshold:
            floor = floor + alpha * (level - floor)
    return onsets


def segment_motion(times: list, ratios: list, cfg: dict) -> list:
    segments = []
    start = None
    peak = 0.0
    last_above = 0.0
    for t, ratio in zip(times, ratios):
        if start is None:
            if ratio >= cfg["motionOnThreshold"]:
                start, peak, last_above = t, ratio, t
            continue
        peak = max(peak, ratio)
        if ratio >= cfg["motionOffThreshold"]:
            last_above = t
            continue
        if t - last_above >= cfg["motionOffHoldSeconds"]:
            segments.append(Segment(start, last_above, peak))
            start = None
    if start is not None:
        segments.append(Segment(start, last_above, peak))
    return segments


def is_swing_candidate(s: Segment, cfg: dict) -> bool:
    return (
        cfg["minSwingSeconds"] <= s.duration <= cfg["maxSwingSeconds"]
        and s.peak >= cfg["minSwingPeak"]
    )


def judge(peaks: list, segments: list, cfg: dict) -> list:
    unused = list(peaks)
    hits = []
    for s in segments:
        if not is_swing_candidate(s, cfg):
            continue
        lo = s.start - cfg["windowBeforeStartSeconds"]
        hi = s.end + cfg["windowAfterEndSeconds"]
        in_window = [p for p in unused if lo <= p.t <= hi]
        if not in_window:
            continue
        best = max(in_window, key=lambda p: p.level)
        unused.remove(best)
        hits.append(Hit(best, s))
    return hits


@dataclass
class Run:
    cfg: dict
    peaks: list
    segments: list
    hits: list


def run(session: Session, cfg: dict) -> Run:
    peaks = detect_audio_peaks(session.audio, cfg)
    segments = segment_motion(session.motion_t, session.roi_ratios(cfg), cfg)
    return Run(cfg, peaks, segments, judge(peaks, segments, cfg))


# ---------------------------------------------------------------- 読み込み


def load_session(path: Path) -> Session:
    config = json.loads((path / "config.json").read_text(encoding="utf-8"))

    audio = []
    with open(path / "audio_blocks.csv", newline="", encoding="utf-8") as f:
        for row in csv.DictReader(f):
            audio.append((float(row["t"]), float(row["peak_db"]), float(row["hp_peak_db"])))

    motion_t, motion_cells = [], []
    with open(path / "motion.csv", newline="", encoding="utf-8") as f:
        reader = csv.reader(f)
        header = next(reader)
        first_cell = header.index("c0")
        for row in reader:
            if not row:
                continue
            motion_t.append(float(row[0]))
            motion_cells.append([float(v) for v in row[first_cell:]])

    app_hits = []
    events = path / "events.csv"
    if events.exists():
        with open(events, newline="", encoding="utf-8") as f:
            for row in csv.DictReader(f):
                if row["kind"] == "hit":
                    app_hits.append(float(row["t"]))

    return Session(path, config, audio, motion_t, motion_cells, app_hits)


def parse_time(text: str) -> float:
    """"83.4" / "1:23.4" / "0:01:23.4" を秒にする。"""
    seconds = 0.0
    for part in text.strip().split(":"):
        seconds = seconds * 60 + float(part)
    return seconds


def load_labels(path: Path) -> list:
    labels = []
    with open(path, newline="", encoding="utf-8-sig") as f:
        for row in csv.DictReader(f):
            if not row.get("t") or not row["t"].strip():
                continue
            kind = row["kind"].strip()
            if kind not in LABEL_KINDS:
                raise ValueError(f"{path}: 不明な kind '{kind}'（使えるもの: {', '.join(LABEL_KINDS)}）")
            labels.append(Label(parse_time(row["t"]), kind, (row.get("note") or "").strip()))
    labels.sort(key=lambda l: l.t)
    return labels


# ---------------------------------------------------------------- 採点


@dataclass
class Score:
    hit_labels: int
    saved_hits: int
    false_saves: Counter
    matched: dict  # hit label index -> Hit

    @property
    def recall(self) -> float:
        return self.saved_hits / self.hit_labels if self.hit_labels else float("nan")

    @property
    def false_total(self) -> int:
        return sum(self.false_saves.values())

    @property
    def false_ratio(self) -> float:
        return self.false_total / self.hit_labels if self.hit_labels else float("nan")

    def passed(self, min_recall: float, max_false_ratio: float) -> bool:
        return self.recall >= min_recall and self.false_ratio <= max_false_ratio


def score(hits: list, labels: list, tol_sound: float, tol_motion: float) -> Score:
    matched: dict = {}
    false_saves: Counter = Counter()
    for hit in hits:
        best, best_d = None, math.inf
        for i, label in enumerate(labels):
            tol = tol_sound if label.kind in SOUND_KINDS else tol_motion
            d = abs(hit.t - label.t)
            if d <= tol and d < best_d:
                best, best_d = i, d
        if best is None:
            false_saves["unlabeled"] += 1
        elif labels[best].kind == "hit":
            if best in matched:
                false_saves["duplicate"] += 1
            else:
                matched[best] = hit
        else:
            false_saves[labels[best].kind] += 1
    hit_labels = sum(1 for l in labels if l.kind == "hit")
    return Score(hit_labels, len(matched), false_saves, matched)


def diagnose_miss(label: Label, r: Run, session: Session, tol_sound: float) -> str:
    """取りこぼした実打について、どの段で落ちたかを返す。"""
    cfg = r.cfg
    near_peaks = [p for p in r.peaks if abs(p.t - label.t) <= tol_sound]
    if not near_peaks:
        levels = [audio_level(b, cfg) for b in session.audio if abs(b[0] - label.t) <= tol_sound]
        top = max(levels) if levels else float("nan")
        return f"音のピークなし（付近の最大 {top:.1f} dB）"

    nearby = [s for s in r.segments if s.start - 3.0 <= label.t <= s.end + 1.0]
    if not nearby:
        ratios = session.roi_ratios(cfg)
        window = [x for t, x in zip(session.motion_t, ratios) if label.t - 2.0 <= t <= label.t + 1.0]
        top = max(window) if window else float("nan")
        return f"動きの区間なし（付近の最大 {top:.3f}）"

    candidates = [s for s in nearby if is_swing_candidate(s, cfg)]
    if not candidates:
        desc = ", ".join(f"長さ{s.duration:.2f}s 強さ{s.peak:.3f}" for s in nearby)
        return f"スイング候補の条件を満たさない（{desc}）"

    for s in candidates:
        lo = s.start - cfg["windowBeforeStartSeconds"]
        hi = s.end + cfg["windowAfterEndSeconds"]
        if any(lo <= p.t <= hi for p in near_peaks):
            return f"時間窓内の音が他の候補に使われた、またはより大きい音が選ばれた（区間 {s.start:.2f}〜{s.end:.2f}）"
    desc = ", ".join(f"{s.start:.2f}〜{s.end:.2f}" for s in candidates)
    return f"音が時間窓の外（音 {near_peaks[0].t:.2f}、区間 {desc}）"


# ---------------------------------------------------------------- 出力


def fmt_time(t: float) -> str:
    m, s = divmod(t, 60)
    return f"{int(m)}:{s:05.2f}"


def describe_stats(values: list) -> str:
    if not values:
        return "データなし"
    return (
        f"n={len(values)} 最小 {min(values):.2f} / 中央 {statistics.median(values):.2f} / "
        f"最大 {max(values):.2f}"
    )


def report_single(session: Session, r: Run, labels: list | None, args) -> None:
    print(f"セッション: {session.path}")
    print(f"音のピーク {len(r.peaks)} 件 / 動きの区間 {len(r.segments)} 件"
          f"（スイング候補 {sum(is_swing_candidate(s, r.cfg) for s in r.segments)} 件）"
          f" / 実打 {len(r.hits)} 件")
    if session.app_hits and not args.set:
        print(f"アプリ内の実打 {len(session.app_hits)} 件（設定を変えていなければ一致するはず）")

    if labels is None:
        print()
        for hit in r.hits:
            print(f"  {fmt_time(hit.t)}  {hit.impact.level:6.1f} dB  "
                  f"区間 {fmt_time(hit.segment.start)}〜{fmt_time(hit.segment.end)}")
        return

    sc = score(r.hits, labels, args.tol_sound, args.tol_motion)
    print_score(sc, args)

    misses = [(i, l) for i, l in enumerate(labels) if l.kind == "hit" and i not in sc.matched]
    if misses:
        print("\n取りこぼした実打:")
        for _, label in misses:
            note = f"  [{label.note}]" if label.note else ""
            print(f"  {fmt_time(label.t)}  {diagnose_miss(label, r, session, args.tol_sound)}{note}")

    wrong = [h for h in r.hits if h not in sc.matched.values()]
    if wrong:
        print("\n誤って保存したもの:")
        for hit in wrong:
            near = min(labels, key=lambda l: abs(l.t - hit.t), default=None)
            what = f"{near.kind} {fmt_time(near.t)}" if near and abs(near.t - hit.t) <= args.tol_motion else "ラベルなし"
            print(f"  {fmt_time(hit.t)}  {hit.impact.level:6.1f} dB  近いラベル: {what}")

    # 時間窓とデバウンス幅を決める材料
    leads = [h.t - h.segment.start for h in sc.matched.values()]
    print(f"\n動き開始からインパクト音まで（秒）: {describe_stats(leads)}")
    tails = [h.segment.end - h.t for h in sc.matched.values()]
    print(f"インパクト音から動き終了まで（秒）: {describe_stats(tails)}")

    onsets = audio_onsets(session.audio, r.cfg)
    counts, gaps = Counter(), []
    for label in labels:
        if label.kind != "hit":
            continue
        near = [t for t in onsets if label.t - args.tol_sound <= t <= label.t + 1.0]
        counts[len(near)] += 1
        gaps += [b - a for a, b in zip(near, near[1:])]
    print("1ショットあたりの音の立ち上がり数: "
          + ", ".join(f"{k}回={v}球" for k, v in sorted(counts.items())))
    print(f"立ち上がり同士の間隔（秒）: {describe_stats(gaps)}")


def print_score(sc: Score, args) -> None:
    verdict = "合格" if sc.passed(args.min_recall, args.max_false_ratio) else "不合格"
    breakdown = ", ".join(f"{k} {v}" for k, v in sorted(sc.false_saves.items())) or "なし"
    print(f"\n実打の保存率: {sc.saved_hits}/{sc.hit_labels} = {sc.recall:.1%}（基準 {args.min_recall:.0%} 以上）")
    print(f"誤って保存: {sc.false_total} 件 = 実打数の {sc.false_ratio:.1%}（基準 {args.max_false_ratio:.0%} 以下）"
          f"  内訳: {breakdown}")
    print(f"判定: {verdict}")


def parse_value(key: str, text: str):
    kind = TUNABLE[key]
    if kind == "bool":
        return text.strip().lower() in ("1", "true", "yes")
    if kind == "roi":
        parts = [float(v) for v in text.split(":")]
        if len(parts) != 4:
            raise ValueError("roi は x0:y0:x1:y1 で指定する")
        return parts
    return float(text)


def parse_sets(items: list) -> list:
    """--set key=v1,v2 のリストを [(key, [値...]), ...] にする。"""
    result = []
    for item in items or []:
        key, _, values = item.partition("=")
        key = key.strip()
        if key not in TUNABLE:
            raise SystemExit(f"変えられないキー: {key}（使えるもの: {', '.join(TUNABLE)}）")
        result.append((key, [parse_value(key, v) for v in values.split(",")]))
    return result


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="POC-01 のログを再解析する")
    parser.add_argument("session", type=Path, help="セッションフォルダ（config.json などがある場所）")
    parser.add_argument("--labels", type=Path, help="正解ラベル（t,kind[,note]）。省略時はセッション内の labels.csv を探す")
    parser.add_argument("--set", action="append", metavar="KEY=V1,V2", help="設定を上書きする。複数値なら総当たり")
    parser.add_argument("--tol-sound", type=float, default=0.5, help="hit/neighbor ラベルとの対応付けの許容差（秒）")
    parser.add_argument("--tol-motion", type=float, default=2.0, help="それ以外のラベルとの対応付けの許容差（秒）")
    parser.add_argument("--min-recall", type=float, default=0.9)
    parser.add_argument("--max-false-ratio", type=float, default=0.1)
    parser.add_argument("--top", type=int, default=20, help="総当たりで表示する件数")
    args = parser.parse_args(argv)

    session = load_session(args.session)
    labels_path = args.labels or (args.session / "labels.csv")
    labels = load_labels(labels_path) if labels_path.exists() else None

    sets = parse_sets(args.set)
    combos = list(itertools.product(*[values for _, values in sets])) or [()]

    if len(combos) == 1:
        cfg = dict(session.config)
        cfg.update({key: value for (key, _), value in zip(sets, combos[0])})
        report_single(session, run(session, cfg), labels, args)
        return 0

    if labels is None:
        raise SystemExit("総当たりには正解ラベルが必要（--labels）")

    rows = []
    for combo in combos:
        cfg = dict(session.config)
        cfg.update({key: value for (key, _), value in zip(sets, combo)})
        sc = score(run(session, cfg).hits, labels, args.tol_sound, args.tol_motion)
        rows.append((combo, sc))
    rows.sort(key=lambda row: (
        not row[1].passed(args.min_recall, args.max_false_ratio), -row[1].recall, row[1].false_ratio))

    keys = [key for key, _ in sets]
    print(f"{len(rows)} 通り中 合格 {sum(sc.passed(args.min_recall, args.max_false_ratio) for _, sc in rows)} 通り\n")
    print(" | ".join(keys + ["保存率", "誤保存率", "内訳", "判定"]))
    for combo, sc in rows[: args.top]:
        values = [":".join(f"{v:g}" for v in c) if isinstance(c, list) else f"{c:g}" if isinstance(c, float) else str(c)
                  for c in combo]
        breakdown = " ".join(f"{k}{v}" for k, v in sorted(sc.false_saves.items())) or "-"
        verdict = "合格" if sc.passed(args.min_recall, args.max_false_ratio) else ""
        print(" | ".join(values + [f"{sc.recall:.1%}", f"{sc.false_ratio:.1%}", breakdown, verdict]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
