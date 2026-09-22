# POC-03 フレームレートと発熱

目的と合否基準は [`docs/poc/poc-03-framerate.md`](../../docs/poc/poc-03-framerate.md)。
ここにあるのは実験用のコードで、製品コードとして残す前提ではない。

| 場所 | 中身 |
|---|---|
| `POC03/` | 計測アプリ（iOS 18、実機のみ） |
| `POC03/CaptureConfig.swift` | 暫定値。定数はここにだけ置く |
| `POC03/ThermalRecorder.swift` | 撮影、書き出し、記録、発熱時の fps 降格 |
| `tools/summarize.py` | セッションの集計と横並びの比較（Python 3.10 以上、標準ライブラリのみ） |

動き検出は POC-01 の `FrameMotionMeter.swift` と `DetectionConfig.swift` を `project.yml` からパスで参照している（コピーしていない）。製品でもカメラ・符号化と一緒に動き検出が常時回るため、その負荷も含めて測る。

このアプリは負荷を測るためにセッション全体を1本の動画に書き続ける。製品の撮影方式（1球＝1クリップ、リングバッファ）とは別物で、符号化の負荷をかけ続けるための手段にすぎない。

## 1. ビルド（Mac）

```sh
brew install xcodegen
cd poc/poc03-framerate
xcodegen generate
open POC03Framerate.xcodeproj
```

Xcode の Signing & Capabilities で Team を選び、iPhone を繋いで実行する。

## 2. 画面と設定

画面で変えられるのは次の3つ。計測中に変えられるのは画面暗転だけ。

| 項目 | 内容 |
|---|---|
| fps | 60 / 120。1080p で出せない端末では解像度か fps を下げ、下げた内容を画面と `meta.json` に出す |
| 計測中は画面を暗くする | 黒一色にして明るさを0にする。黒い画面をタップすると元に戻る（戻したことも記録される） |
| 動き検出（POC-01）を回す | 既定でオン。オフにすると、動き検出のぶんの負荷の差が分かる |

それ以外は `POC03/CaptureConfig.swift` を書き換えてビルドし直す。主なもの:

| キー | 既定 | 内容 |
|---|---|---|
| `logIntervalSeconds` | 10 | `status.csv` に1行書く間隔（秒） |
| `sessionLimitMinutes` | 0 | 0 なら上限なし。超えたら自動で終了する |
| `autoDowngrade` | true | 発熱時に fps を下げる |
| `downgradeThermalState` | 2 | これ以上で下げる（0 nominal / 1 fair / 2 serious / 3 critical） |
| `downgradeSteps` | 120→60、60→30 | 発熱状態が一段上がるたびに一段下げる |
| `restoreAfterCooling` / `restoreThermalState` | false / 1 | 冷えたら開始時の fps に戻す |
| `videoBitRates` | 60fps 8Mbps、120fps 14Mbps | 平均ビットレート。ファイルサイズはほぼこれで決まる |

fps を途中で下げても動画ファイルは分けない。各フレームの時刻がそのまま記録されるので、1本の可変フレームレートの動画として正しい速さで再生される。

## 3. 計測A：60fps と 120fps の見え方

### 撮り方

同じスイングを両方の fps で見比べるため、次のどちらかで撮る。

- **1台で撮る（推奨）**: 120fps で撮り、あとで1コマおきに間引いて 60fps を作る（下の「切り出し」参照）。まったく同じスイングで比べられる。ただしシャッター速度は 120fps のままなので、60fps で撮った時のブレは再現されない
- **2台並べて撮る**: 同じ機種を2台並べ、片方を 60fps、もう片方を 120fps で同時に撮る。実際の 60fps のブレも含めて比べられる

置き方は製品と同じ。打席の後方2mに縦向きで立てかけ、全身が入るようにする。実打を10球以上撮る。
暗い打席や夕方は 120fps だと露光が足りず暗く粗くなりやすい。天候と時刻をメモしておく。

### 切り出し（Mac、ffmpeg）

```sh
brew install ffmpeg
# 1球ぶん（インパクトの5秒前から8秒）を切り出す。12:34.5 のインパクトなら -ss 12:29.5
ffmpeg -ss 12:29.5 -t 8 -i session.mov -an -c:v libx264 -crf 12 swing1_120.mov
# 1コマおきに間引いて 60fps にする
ffmpeg -i swing1_120.mov -vf "select='not(mod(n\,2))',setpts=N/60/TB" -r 60 -c:v libx264 -crf 12 swing1_60.mov
```

### 4コマの位置決め（目視）

QuickTime Player で開き、← → キーで1コマずつ送る。スイングごとにアドレス／トップ／インパクト／フィニッシュのコマを選び、表に残す。

| swing | fps | address | top | impact | finish | インパクトのコマの見え方 |
|---|---|---|---|---|---|---|
| 1 | 120 | 1.250 | 2.108 | 2.358 | 3.500 | 基準 |
| 1 | 60 | 1.250 | 2.100 | 2.350 | 3.500 | 頭・腰の位置は120fpsと見分けがつかない |

- 時刻は切り出したクリップの先頭からの秒（QuickTime の表示を「フレーム番号」にしてもよい）
- インパクトのずれは、60fps で選んだコマと 120fps で選んだコマの時刻の差で見る。コマの間隔は 60fps で 16.7ms、120fps で 8.3ms
- このアプリが比べるのは頭・肩・腰・体の傾きといった身体の位置。インパクトのコマで体の位置が 120fps と見分けがつくほど違うかを主に見る。クラブヘッドの位置が違うのは想定内（`product.md` で範囲外）

### 重ね合わせ（目視）

同じ fps の2球をインパクトのコマで揃えて重ね、60fps と 120fps で見え方を比べる。

```sh
# swingA と swingB をインパクトの位置で揃えて切り出してから、半透明で重ねる
ffmpeg -i swingA_60.mov -i swingB_60.mov -filter_complex "blend=all_mode=average" -c:v libx264 -crf 12 overlay_60.mov
ffmpeg -i swingA_120.mov -i swingB_120.mov -filter_complex "blend=all_mode=average" -c:v libx264 -crf 12 overlay_120.mov
```

主観でよい。「60fps の方が明らかに見劣りするか」を5段階で付け、気になったコマの時刻をメモする。

## 4. 計測B：発熱と電池（60〜90分）

### 条件をそろえる

- 満充電にして電源から外す。低電力モードはオフ。他のアプリは終了する
- ケースの有無、置き場所（直射日光が当たるか）、気温、天気をメモする
- 前の計測の熱が残らないよう、画面上の発熱表示が nominal に戻ってから始める（目安30分以上空ける）
- `sessionLimitMinutes` を 90 にしておくと、終了し忘れても90分で止まる

### 組み合わせ

同じ端末で次の4本を撮る。世代の違う端末があれば、それぞれで同じ4本を撮る。

| fps | 画面暗転 |
|---|---|
| 60 | あり |
| 60 | なし |
| 120 | あり |
| 120 | なし |

動き検出はオンのまま（製品と同じ負荷）。時間があれば動き検出オフの1本を足し、その差を見る。

### 手順

1. 打席の後方に置き、直射日光が当たる状態にする
2. fps と画面暗転を選んで「計測開始」。以降は端末に触れない
3. 60〜90分たったら「計測終了」（または上限で自動終了）
4. 発熱でアプリが落ちた場合も、そこまでの記録と動画は残る（10秒ごとに書き出している）

### fps の自動降格を室内で確かめる

実際に .serious まで熱くならなくても、Xcode で発熱状態を擬似的に変えられる。

1. iPhone を Mac に繋ぎ、Xcode → Window → Devices and Simulators を開く
2. 端末を選び、Device Conditions の Condition で Thermal State を選ぶ。Profile で Serious を選んで Start
3. 画面の「設定 fps」が 120→60（60fps で始めたなら 60→30）に下がり、`events.csv` に `fps_change` が出ることを確かめる
4. Critical にするともう一段下がる。Stop で戻る（`restoreAfterCooling` が true なら開始時の fps に戻る）

## 5. ログの取り出し

「ファイル」アプリ → このiPhone内 → POC03 → `sessions/<日時>/` をAirDropなどでPCへ送る。Mac なら Finder の iPhone 画面の「ファイル」からも取り出せる。
動画が大きい（90分で数GB）ので、集計だけなら `session.mov` 以外を送れば足りる。

| ファイル | 中身 |
|---|---|
| `session.mov` | 通しの動画（音声つき、HEVC）。fps を下げた後は可変フレームレート |
| `config.json` | 計測時の設定 |
| `meta.json` | 端末、実際に使ったフォーマット、フレーム数、落ちたフレーム数、ファイルサイズ、終了理由。落ちた場合は `stopReason` が `running` のまま残る |
| `status.csv` | `logIntervalSeconds` ごとの状態（下表） |
| `events.csv` | 発熱状態の変化、fps の変更、画面暗転の切り替え、カメラの中断など |

`status.csv` の列:

| 列 | 内容 |
|---|---|
| `elapsed_s` | 計測開始からの経過秒 |
| `t` | 動画上の位置（秒） |
| `thermal` | `ProcessInfo.thermalState`（0 nominal / 1 fair / 2 serious / 3 critical） |
| `pressure` | カメラの `systemPressureState`（0 nominal 〜 4 shutdown）。shutdown ではカメラが止まる |
| `battery` / `battery_state` | 電池残量（0〜1、不明は -1）と状態（1 電源なし / 2 充電中 / 3 満充電） |
| `dim` / `brightness` | 画面暗転の有無と画面の明るさ |
| `fps_setting` / `fps_delivered` | 設定した fps と、直前の間隔で実際に届いた fps |
| `frames` / `dropped_capture` / `dropped_writer` | 届いたフレームの累計、カメラ側で落ちた数、書き出しが追いつかず落とした数 |
| `file_bytes` | その時点の動画ファイルの大きさ |
| `motion_ms` | 動き検出の1フレームあたりの平均処理時間（オフなら -1） |

`events.csv` の `kind` と `v1`〜`v3` の意味は `POC03/RunLog.swift` の `event` のコメントにある。発熱状態の変化はここに即時に出るので、到達時刻は `status.csv` の間隔より細かく分かる。

## 6. 集計

```sh
cd poc/poc03-framerate/tools

# 複数のセッションを横に並べる
python summarize.py <セッション1> <セッション2> <セッション3> <セッション4>

# 10分ごとの発熱・電池・fps の推移も出す
python summarize.py <セッション1> <セッション2> --timeline 10
```

出る項目:

- `.fair` / `.serious` / `.critical` に入るまでの時間と、60分以内に `.critical` に達したか（合否基準）
- 電池の減り（1時間あたり %）。充電中の行は除いて計算する
- fps の設定ごとの実測 fps（平均・最小）と、落ちたフレームの数と割合
- fps の設定ごとの1分あたりのファイルサイズと、1クリップ（8秒）に換算した大きさ、セッション合計
- fps 降格の時刻と、その時の発熱状態
- 動き検出の処理時間

合否は `docs/poc/poc-03-framerate.md` のとおり。

- 計測A: 60fps で4コマの位置決めと重ね合わせが実用になること
- 計測B: 60分で `.critical` に達しないこと。達する場合は、fps の自動降格またはセッション長の上限で避けられること（降格後の `.critical` 到達までの時間が延びるか、上限の時間内に収まるかで見る）

テスト:

```sh
cd poc/poc03-framerate/tools
python -m unittest test_summarize.py
```
