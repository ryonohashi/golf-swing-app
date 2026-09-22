# SwingNote（製品アプリ）

Penpot の画面モック（`docs/design/penpot/`）をもとにした製品UIの先行実装。
撮影と姿勢推定はまだモックで、POC が通った後に実装を差し込む。

見た目の正は Penpot のモック、振る舞いの正は `docs/` 以下の仕様。食い違う箇所は仕様に合わせている（下の「モックとの違い」）。

## ビルド

Mac（Xcode 16 以降）で行う。この README を書いた Windows 環境ではコンパイルしていない。

```sh
brew install xcodegen      # 未導入なら
cd app
xcodegen generate          # SwingNote.xcodeproj ができる
open SwingNote.xcodeproj
```

- Signing & Capabilities で Team を選ぶ（`project.yml` の `DEVELOPMENT_TEAM` は空）
- 最小 iOS 18、iPhone のみ、Swift 5 言語モード、外部依存なし
- 画面はすべて `#Preview` で確認できる（ダミーデータ入り、屋外表示の版もあり）。撮影まわりは実機でなくても動く（モックのため）

### 開発用の操作

- DEBUG ビルドでは、撮影画面右上の状態表示（「待機中」）を1秒長押しすると、モック撮影が実打を1回起こす（フラッシュ → 一覧に1球追加）
- プレビューでは `CaptureCoordinator.preview()` が5秒ごとにスイング候補を出し、4回に1回は素振りとして捨てる

## 構成

```
app/
  project.yml                     XcodeGen の定義
  SwingNote/
    App/          SwingNoteApp（ModelContainer・環境の注入）、Router（画面遷移・向きの固定・画面の明るさ）
    Config/       AppConfig（暫定値を1箇所に集約）、AppPreferences（UserDefaults のキー）
    Theme/        Theme（配色トークン・角丸・サイズ・フォント）。通常＝ダーク、屋外表示＝明るい配色
    Models/       SwiftData モデル（Session / ClubBlock / Swing / BaseSwingPin）とタグの列挙
    Services/     CaptureService（撮影の窓口）、SwingAnalysisProvider（姿勢推定の窓口）、
                  CaptureCoordinator（クリップの取り込みとフラッシュ）、SwingLibrary（保存・基準スイング）、
                  MediaServices（静止画の取り出し・ティント・カメラロール書き出し）
    Views/        画面（Capture / List / Compare / BaseSwing / Settings）と共通部品
    Preview/      プレビュー用のダミーデータ
```

### 画面とモックの対応

| モック | 画面 | ファイル |
|---|---|---|
| 01 撮影待機 | `CaptureView` | `Views/Capture/CaptureView.swift` |
| 02 クリップ確定フラッシュ | `FlashView` | `Views/Capture/FlashView.swift` |
| 03 スイング一覧 | `SwingListView` | `Views/List/SwingListView.swift` |
| 04 重ね合わせ | `CompareView`（重ね合わせ） | `Views/Compare/` |
| 05 4コマ | `CompareView`（4コマ） | `Views/Compare/` |
| 06 基準スイング | `BaseSwingView` | `Views/BaseSwing/BaseSwingView.swift` |
| 07 設定 | `SettingsView` | `Views/Settings/SettingsView.swift` |
| 08 屋外表示 | `Theme.outdoor`（全画面に適用） | `Theme/Theme.swift` |

### データ

- `Session`：同じ暦日のスイングを1つにまとめる（`SessionRule`、暫定）
- `ClubBlock`：クラブを変えた区切り。クラブは設定した値が以降の球に付き続け、変えた後の最初の1球で新しいブロックが始まる
- `Swing`：1球＝1クリップ。番号・動画ファイル名・撮影日時・クラブ・アングル・長さ・チェックポイント（アドレス／トップ／インパクト／フィニッシュ）・身体の動きの値
- `BaseSwingPin`：基準スイングのピン留め。`slot` に一意制約をかけ、行が1つしか存在できない（v1 は1本）
- 動画は `Application Support/Clips/` に置き、モデルにはファイル名だけを持つ。CloudKit は `cloudKitDatabase: .none` で明示的に切っている

## モックになっているもの / 後から差し込むもの

| 窓口 | 今 | 差し込むもの |
|---|---|---|
| `CaptureService` | `MockCaptureService`：カメラを使わず状態だけを遷移させる。本体アプリでは自動で球を出さない | POC-01（動作＋インパクト音の AND 判定、デバウンス）と POC-02（チャンクのリングバッファ、前後の切り出し）を組み合わせた実装。確定したクリップを `CapturedClip`（一時ファイル・インパクト時刻）として `onClip` に渡せばよい。サーマル監視による fps 低下は `frameRate`、省電力は `status = .powerSaving` で画面に出る |
| カメラプレビュー | `CameraPreviewPlaceholder`（グラデーション） | 撮影実装の `AVCaptureVideoPreviewLayer` |
| `SwingAnalysisProvider` | `MockSwingAnalysisProvider`：番号から決まるダミー値 | Vision（`VNDetectHumanBodyPoseRequest`）でチェックポイントと頭の移動・肩の回転・腰のスウェー・体の傾き・テンポを出す実装 |
| 動画がない時の表示 | `ClipPlaceholder`（グラデーション＋SF Symbols） | 実クリップがあれば自動で `AVAssetImageGenerator` の静止画・`AVPlayer` の再生に切り替わる |

実クリップ側の処理はモックなしで書いてある：

- 重ね合わせのティントは `AVVideoComposition.videoComposition(with:applyingCIFiltersWithHandler:)` で、A を寒色、B を暖色の `CIColorMatrix` に通す（`Tint`）
- 2本はインパクト時刻を揃え、`setRate(_:time:atHostTime:)` で同じホスト時刻から再生する
- 4コマとサムネイルは `AVAssetImageGenerator` で取り出す
- 共有ボタンはカメラロールへの書き出し（追加のみの権限）

暫定値（前5秒・後3秒、リングバッファ8秒、60fps、チャンク長・デバウンス幅は未定）は `Config/AppConfig.swift` の `CaptureConfig` に集めてある。設定画面の「クリップ」欄もここから表示している。

## モックとの違い

| 箇所 | モック | 実装 | 理由 |
|---|---|---|---|
| 撮影モードの名前 | 「ボール打撃」 | 「自動」（説明は「スイング動作と打球音がそろった時に保存」） | 仕様（spec-capture / spec-ui）は 自動 / 手動 |
| 手動モードの録画ボタン | なし | 手動モードの時だけ撮影画面に出す | 仕様で手動は「ボタン操作で1クリップずつ録画」。自動モードでは出さない |
| 撮影待機の暗転 | なし | 30秒操作がないと暗転し、タップで戻る | spec-capture「撮影待機中は画面を暗転する」 |
| 撮影画面の最新球サムネイル | タップ先の指定なし | スイング一覧を開く（一覧の先頭に最新球 vs 基準スイングの1タップ比較がある）。1球もない時は「一覧」ボタン | 一覧と設定への入口が他にないため |
| 一覧のヘッダー | 設定ボタンのみ | 戻るボタン、基準スイングボタン（ピン）、設定ボタン | 撮影画面へ戻る手段と、06 基準スイングへの入口が必要 |
| 一覧で1球だけ選んだ時 | 定義なし | 「#nを基準スイングにする」ボタンと「もう1球選ぶと比較できます」 | 基準スイングを選ぶ操作の置き場所。3球目のタップでは勝手に入れ替えず、外してから選び直してもらう |
| 一覧の過去セッション | 今日のみ | 今日の下に過去のセッションを日付ごとに並べる | 日をまたぐ比較（spec-compare）で過去の球を選べるようにする |
| 基準スイング未設定時 | 定義なし | 一覧カードと06に案内を出す | — |
| 重ね合わせの映像 | 横長に切り抜き | 縦動画をそのまま収める（`resizeAspect`） | 縦動画を横長に切り抜くと頭や足が切れる |
| 4コマの各コマ | 横長に切り抜き、4段が1画面 | 9:16 のまま並べ、縦にスクロール | 同上 |
| 4コマ画面の数値表 | なし | 4コマの下にも身体の動きの数値を出す | 4コマから開く既定（クラブ違い）でも数値を見られるように |
| 数値表の項目 | 頭の移動・肩の回転・腰のスウェー・テンポ | 体の傾き（アドレス）を追加。表の下に「2D映像から求めた値で、フェース角や打点は映らない」と注記 | product.md の「示せること」に合わせる |
| 比較画面の横向き | なし | 左に横並びの動画（または4コマを A 段・B 段）、右に操作と数値 | spec-ui「縦＝重ね合わせ、横＝横並び」 |
| クラブ違い・アングル違い | なし | クラブ違いは4コマで開き「アドレスの幅とボール位置の違いは正常」と表示。アングル違いは重ね合わせの代わりに横並び | spec-compare |
| 日をまたぐ比較の凡例 | なし | 「9/20 #15 基準スイング」のように日付を付ける | 番号はセッション内の通し番号なので |
| 共有ボタン | 共有アイコン | カメラロールへの保存（どちらの球を保存するか選ぶ） | v1 のエクスポートはカメラロールへの書き出し。コーチへの動画共有機能は落としている |
| クラブの変更 | 「変更」の先は未定義 | 4列のクラブボタン（各60pt）のシート | 1タップで変えられるように |
| フォント | Noto Sans JP / Inter Tight | システムフォント（和文は標準、数字は `monospacedDigit()`）。サイズ・太さはモックに合わせた | フォントファイルとライセンスを同梱しないため |
| 写真 | 参考画像の切り抜き | 動画がない時はグラデーション＋SF Symbols | モックの写真はプレースホルダ |

屋外表示は色を明るくするだけでなく、オンの間は画面の明るさを最大にし、オフにすると元に戻す（spec-ui「屋外＝明るい背景＋輝度最大」）。

## 実機で確かめること

- 比較画面だけ横向きになり、戻ると縦に戻るか（`OrientationLock`。`setNeedsUpdateOfSupportedInterfaceOrientations` と `requestGeometryUpdate` を使用）
- 2本の同時再生のずれ（`setRate(_:time:atHostTime:)`）
- ティントの色味（`Tint.apply` の係数）
- 60pt の当たり判定を持つ細いスライダーが ScrollView のスクロールと干渉しないか
