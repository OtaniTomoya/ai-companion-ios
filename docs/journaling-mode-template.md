# ジャーナリングモード雛形

## 目的

会話アバターを、雑談相手だけでなく「今日あったことを聞き取りして整理する相手」として使えるようにする。
ユーザーが日記を書く前提ではなく、アバターが質問し、ユーザーが音声またはテキストで答えることで、1日の出来事・感情・写真・移動履歴をまとめる。

## 入口

- 画面右上に常時表示のジャーナリングボタンを置く。
- 設定パネルや操作パネルとは別扱いにし、アプリ起動直後から見えるようにする。
- ボタンを押すと、通常会話からジャーナリングモードへ切り替わる。
- ジャーナリング中でも、通常会話へ戻れる終了ボタンを用意する。

## 最初にできること

### 1. 今日の聞き取り

ジャーナル用プロンプトに切り替わったアバターが、埋めたい項目を意識しながら短い質問を投げ、ユーザーは通常の会話入力または音声で答える。
ジャーナリング画面内に長文を書くのではなく、メイン画面で会話する流れを基本にする。

- 今日はどんなことがあったか
- 印象に残った出来事は何か
- 誰と会ったか、何を話したか
- うまくいったこと、疲れたこと、気になっていること
- 明日に残したいこと、忘れたくないこと

回答は会話ログとして保存し、最後に日記形式へ要約する。

### 2. 画像からの振り返り

その日に撮った写真を取り込み、聞き取りの材料にする。

- 今日撮影した写真を一覧する
- 写真の撮影時刻を使って、出来事の順番を推定する
- ユーザーが選んだ写真について「これは何をしていた時？」と質問する
- 写真ごとに短いメモを付ける
- 写真そのものは必要な場合だけ保存し、基本は参照情報とメモを残す

初期実装では、写真の自動解析は必須にしない。
まずは「今日の写真を選ぶ」「写真に紐づけて会話する」までを対象にする。

### 3. 移動履歴からの振り返り

その日の移動履歴を使って、出来事を思い出しやすくする。

- 今日訪れた場所や移動区間を時系列で表示する
- 滞在時間が長い場所を候補として提示する
- 「この時間帯は何をしていた？」と聞く
- 場所名はユーザーが必要に応じて編集できるようにする

初期実装では、既存の `LocationAuthorizationManager` を使って使用中のみの位置記録を行う。
標準の前景位置更新を使い、ジャーナリング素材として必要な範囲に絞って記録する。
取得した位置サンプルは日記素材として保存し、ジャーナリング終了時にその日の位置ログを日記へ含める。

### 4. 音声での聞き取り

通常会話と同じ音声入力を使い、日記用の回答として扱う。

- ジャーナリング中の音声は「日記素材」として会話ログに分類する
- 聞き返しや要約確認を挟む
- 長い回答は、出来事・感情・人物・場所・次の行動へ分解する
- 音声入力が使えない場合はテキスト入力でも同じ流れにする

## ジャーナリングの流れ

1. ジャーナリングボタンを押す
2. 今日の日付でセッションを開始する
3. 使う素材を選ぶ
   - 会話のみ
   - 今日の写真
   - 移動履歴
   - 写真と移動履歴
4. アバターが聞き取りを開始する
5. メイン画面へ戻り、アバターが「今日はどんなことがあった？」から質問する
6. ユーザーが会話で答えるたびに、次の質問をアバターが行う
7. 必要に応じて写真や場所を提示しながら質問する
8. 最後に要約を作る
9. ユーザーが確認・修正する
10. その日のジャーナルとして保存する

## 出力する日記の形

```markdown
# 2026-04-30 のジャーナル

## 今日の要約

## 出来事

## 印象に残ったこと

## 気持ち

## 写真メモ

## 移動メモ

## 明日に持ち越すこと
```

## データ雛形

```swift
struct JournalSession {
    let id: UUID
    let date: Date
    var mode: JournalMode
    var messages: [JournalMessage]
    var photoItems: [JournalPhotoItem]
    var locationItems: [JournalLocationItem]
    var summary: JournalSummary?
}

enum JournalMode {
    case conversationOnly
    case withPhotos
    case withLocationHistory
    case withPhotosAndLocationHistory
}

struct JournalMessage {
    let id: UUID
    let createdAt: Date
    let speaker: JournalSpeaker
    let text: String
    let source: JournalMessageSource
}

enum JournalSpeaker {
    case user
    case assistant
    case system
}

enum JournalMessageSource {
    case voice
    case text
    case photoPrompt(photoID: UUID)
    case locationPrompt(locationID: UUID)
}

struct JournalPhotoItem {
    let id: UUID
    let assetIdentifier: String
    let capturedAt: Date?
    var userMemo: String?
    var includedInSummary: Bool
}

struct JournalLocationItem {
    let id: UUID
    let recordedAt: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double?
    let speed: Double?
}

struct JournalSummary {
    var title: String
    var overview: String
    var events: [String]
    var feelings: [String]
    var photoNotes: [String]
    var locationNotes: [String]
    var carryOvers: [String]
}
```

## 聞き取りプロンプト雛形

```text
あなたは会話形式で日記を作る聞き取り役です。
ユーザーが自然に話せるように、質問は一度に1つだけ行います。
回答を急いで要約せず、具体的な出来事、感情、人物、場所、明日に残すことを少しずつ確認してください。

今日の日付: {{date}}
利用できる素材: {{available_context}}

進め方:
1. まず今日全体の印象を聞く
2. 印象に残った出来事を1つずつ深掘りする
3. 写真がある場合は、撮影時刻順に必要なものだけ触れる
4. 移動履歴がある場合は、長い滞在や移動の前後だけ確認する
5. 最後に短い日記案を提示し、修正したい点を聞く

制約:
- 質問は短くする
- 質問案を確認する「〜で大丈夫？」「この質問でいい？」は出さず、質問そのものだけを自然に言う
- 1回の回答で複数の項目が埋まった場合は、該当項目をすべて filled として返す
- 読み上げ文は `<answer>`、項目状態は `<journal>` 内の JSON で分ける
- 推測で断定しない
- 写真や位置情報の扱いはユーザーに確認する
- ネガティブな出来事を無理に前向きに言い換えない
- 保存前に必ず確認を取る
```

## 初期実装の範囲

- 右上に常時表示のジャーナリングボタンを追加する
- ジャーナリング中かどうかを `ConversationViewModel` とは別の状態で持つ
- 聞き取りメモ、通常会話ログ、写真、位置サンプルから日記を生成する
- ジャーナリング開始時は入力シートを閉じ、WebSocket セッションにジャーナルモードと聞き取り項目を送る
- ユーザーの会話発話を取り込むたびに、LLM が埋まっていない項目を自然に補う質問を1つだけ返す
- ジャーナリング終了時に「今日の出来事をまとめたよ〜」と発話し、日記詳細を表示する
- 日記をローカルに蓄積し、今日・昨日・履歴から確認できる導線を作る
- 写真は `PhotosPicker` で選択し、メモを紐づけられるようにする
- 位置情報は使用中のみ許可の前景更新を使って記録する
- 位置サンプルは位置更新のデリゲートから直接保存し、10秒または5m移動ごとに重複を抑えながら蓄積する

## 現在の実装と残課題

- 写真は `PhotosPicker` で読み込んだ画像データをアプリ内にコピーして保存する
- ジャーナル本文、写真コピー、位置サンプルは端末内のApplication Support領域に保存する
- journal mode中は、最近の回答、項目状態、写真枚数、位置サンプル数、任意の予定表要約を接続先サーバーへjournal prompt contextとして送る
- vision modeは有効時のみ、直近のカメラフレームを接続先サーバーへ送る
- 未実装の残課題は、写真メタデータ削除、明示的なエクスポート/削除UI、通常会話ログとジャーナリングログの統合表示方針
