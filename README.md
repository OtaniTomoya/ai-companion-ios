# AI Companion iOS

リアルタイムAIコンパニオン用のSwiftUI iOSクライアントです。
MotionPNGTuber形式のアバターを表示し、WebSocket経由でAIバックエンドに接続します。音声/テキスト会話、vision modeでのカメラ文脈送信、会話文脈からの日記作成を扱います。

## リポジトリ範囲

このリポジトリにはiOSアプリだけを置いています。

対応するバックエンドは別リポジトリで管理しています。

```text
https://github.com/OtaniTomoya/ai-companion-backend
```

iOSアプリは互換性のある任意のバックエンドに `wss://.../ws` で接続できます。Debugビルドでは、ローカル開発用に `ws://127.0.0.1:8000/ws` も利用できます。

## 主な機能

- バンドルしたWebViewプレイヤーによるMotionPNGTuberアバター表示
- ローカルマイク音量、または受信した音声レベルに連動するリップシンク
- WebSocket接続状態、テキスト入力、マイク入力、リモート音声再生、ミュート、会話履歴表示
- 直近のカメラフレームを会話文脈として送るvision mode
- 会話、選択写真、位置サンプル、任意の予定表文脈をローカルの日記にまとめるjournal mode
- WebSocket URL、APIキー、割り込み発話、予定表文脈、リップシンク感度の設定

## 必要環境

- Xcode 17以降
- iOS 17以降のシミュレータまたは実機
- ライブAI応答用の互換バックエンド

## Build

```bash
xcodebuild build \
  -project "chat app.xcodeproj" \
  -scheme "chat app" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath /tmp/ai-companion-ios-deriveddata
```

## バックエンド接続

Debugビルドの既定値は次の通りです。

```text
ws://127.0.0.1:8000/ws
```

リモートバックエンドを使う場合は、アプリのWebSocket URLを次の形式に設定します。

```text
wss://<your-backend-host>/ws
```

バックエンドがAIAvatar APIキーを要求する場合は、同じキーをアプリの設定画面に入力します。入力したキーはiOS Keychainに保存されます。

## プライバシー上の注意

有効にした機能に応じて、このアプリはマイク音声、カメラフレーム、選択写真、位置サンプル、予定表要約、日記内容を扱います。

- 音声とテキストは、設定したWebSocketバックエンドへ送信されます。
- vision modeでは、有効化中に直近のカメラフレームをbase64 JPEGの会話文脈として、設定したバックエンドへ送信します。
- 日記本文、選択写真のコピー、位置サンプルは、アプリのApplication Supportディレクトリにローカル保存されます。アプリまたはユーザーが削除するか、アプリデータが削除されるまで保持されます。
- journal modeでは、会話抜粋、項目の進行状況、選択写真数、位置サンプル数、任意の予定表要約を、journal prompt contextとして設定済みバックエンドへ送信することがあります。完成した日記本文はアプリ側で生成し、ローカルに保存します。
- 選択写真は元画像データからアプリ内ストレージへコピーされます。元画像に埋め込まれたメタデータが残る可能性があります。
- アプリに入力したAPIキーはiOS Keychainに保存されます。

信頼できないバックエンドには接続しないでください。

## Third-party assets

MotionPNGTuberプレイヤーとバンドル済みアバターアセットについては、次のファイルに記載しています。

```text
chat app/MotionPNGTuberPlayer/THIRD_PARTY_NOTICES.md
```

## License

このプロジェクト全体に対するオープンソースライセンスは、現時点では付与していません。GitHubで公開されているため閲覧はできますが、後日ライセンスを追加しない限り、再利用、再配布、派生物の作成は許可していません。
