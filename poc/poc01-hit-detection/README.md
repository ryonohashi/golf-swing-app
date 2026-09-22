# POC-01 実打の判定（動作＋インパクト音）

目的と合否基準は [`docs/poc/poc-01-hit-detection.md`](../../docs/poc/poc-01-hit-detection.md)。
ここにあるのは実験用のコードで、製品コードとして残す前提ではない。

| 場所 | 中身 |
|---|---|
| `POC01/` | 計測アプリ（iOS 18、実機のみ） |
| `POC01/DetectionConfig.swift` | 暫定値。定数はここにだけ置く |
| `POC01/HitDetector.swift` | 判定ロジック |
| `tools/replay.py` | ログの再解析・採点・総当たり（Python 3.10 以上、標準ライブラリのみ） |

判定ロジックは `HitDetector.swift` と `tools/replay.py` の2か所にある。片方を変えたらもう片方も合わせる。

## 1. ビルド（Mac）

```sh
brew install xcodegen
cd poc/poc01-hit-detection
xcodegen generate
open POC01HitDetection.xcodeproj
```

Xcode の Signing & Capabilities で Team を選び、iPhone を繋いで実行する。

## 2. 練習場での計測

1. 打席の後方2mに縦向きで置く。黄色の破線（ROI）に自分の全身が入り、隣の打席がなるべく入らない位置にする
2. 「計測開始」。以降は端末に触れない。画面の数字が実打と判定した回数
3. 実打・素振り・ワッグル・アドレス調整を混ぜて打つ。隣の打席の打球音は自然に入る
4. 「計測終了」

画面下の2本のバーは直近0.1秒の音の大きさと、ROI内の動き量。白い縦線は `audioAbsoluteMinDb` と `motionOnThreshold` の位置。置き場所を決める時の目安に使う。

## 3. ログの取り出し

「ファイル」アプリ → このiPhone内 → POC01 → `sessions/<日時>/` をAirDropなどでPCへ送る。Mac なら Finder の iPhone 画面の「ファイル」からも取り出せる。

| ファイル | 中身 |
|---|---|
| `reference.mov` | 通しの参照動画（音声つき） |
| `config.json` | 計測時の設定 |
| `meta.json` | 端末、フレーム数、落ちたフレーム数、アプリ内の実打数 |
| `audio_blocks.csv` | 10ms ごとの音のピーク・RMS・ハイパス後のピーク（dBFS） |
| `motion.csv` | フレームごとの処理時間と、6×8セルそれぞれの動き量 |
| `events.csv` | 音のピーク、動きの区間、実打、発熱状態、落ちたフレーム |

時刻 `t` はすべて `reference.mov` の再生位置（秒）と同じ。
動き量はセル単位で残しているので、ROI は後から変えて再解析できる。

## 4. 正解ラベルを作る

`reference.mov` を見ながら、セッションフォルダに `labels.csv` を作る。

```csv
t,kind,note
1:23.40,hit,
1:41.10,practice,
1:55.00,neighbor,
2:03.50,waggle,
2:10.00,address,
2:30.20,hit,ダフり
```

| kind | 何か | t の付け方 |
|---|---|---|
| `hit` | 自分の実打 | インパクトの瞬間 |
| `neighbor` | 隣の打席の実打 | 打球音が鳴った瞬間 |
| `practice` | 自分の素振り | スイングの途中あたり |
| `waggle` | ワッグル | 動きの途中あたり |
| `address` | アドレス調整 | 動きの途中あたり |
| `other` | その他（ボール出し機、会話など） | 音や動きのあった時刻 |

`hit` / `neighbor` は ±0.5秒、それ以外は ±2秒で判定結果と対応付ける（`--tol-sound` / `--tol-motion` で変更可）。

## 5. 再解析

```sh
cd poc/poc01-hit-detection/tools

# 計測時の設定で採点する。取りこぼした実打には、どの段で落ちたかを出す
python replay.py <セッションフォルダ>

# 設定を変えて総当たりする（値はカンマ区切り、roi は x0:y0:x1:y1）
python replay.py <セッションフォルダ> \
  --set audioRelativeThresholdDb=12,16,20,24 \
  --set motionOnThreshold=0.04,0.08,0.12 \
  --set roi=0.15:0.05:0.85:0.95,0.25:0.05:0.75:0.95
```

合否は「実打の保存率90%以上」かつ「誤って保存した件数が実打数の10%以下」（`--min-recall` / `--max-false-ratio`）。
あわせて、時間窓とデバウンス幅を決める材料として次の値を出す。

- 動き開始からインパクト音までの秒数
- 1ショットあたりの音の立ち上がり数と、その間隔

テスト:

```sh
cd poc/poc01-hit-detection/tools
python -m unittest test_replay.py
```
