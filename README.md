# AI Companion iOS

SwiftUI iOS client for a realtime AI companion. The app shows a
MotionPNGTuber-style avatar, connects to a WebSocket AI backend, supports
voice/text conversation, can attach camera context in vision mode, and can help
create local journal entries from conversation context.

## Repository Scope

This repository contains the iOS app only.

The companion backend is managed separately:

```text
https://github.com/OtaniTomoya/ai-companion-backend
```

The iOS app can connect to any compatible backend endpoint using `wss://.../ws`
or, in Debug builds, a local `ws://127.0.0.1:8000/ws` endpoint.

## Features

- MotionPNGTuber avatar rendered through a bundled WebView player.
- Lip-sync driven by local microphone level or received speech audio level.
- WebSocket connection status, text input, microphone input, remote audio
  playback, mute, and conversation transcript.
- Vision mode that sends recent camera frames as conversation context.
- Journal mode that collects conversation, selected photos, location samples,
  and optional calendar context into a local daily journal.
- Settings for WebSocket URL, API key, barge-in, calendar context, and lip-sync
  sensitivity.

## Requirements

- Xcode 17 or later
- iOS 17 or later simulator/device
- A compatible backend endpoint for live AI responses

## Build

```bash
xcodebuild build \
  -project "chat app.xcodeproj" \
  -scheme "chat app" \
  -configuration Debug \
  -destination "generic/platform=iOS Simulator" \
  -derivedDataPath /tmp/ai-companion-ios-deriveddata
```

## Backend Connection

Debug builds default to:

```text
ws://127.0.0.1:8000/ws
```

For a remote backend, set the app's WebSocket URL to:

```text
wss://<your-backend-host>/ws
```

If the backend requires an AIAvatar API key, enter the same key in the app's
settings. The key is stored in the iOS Keychain.

## Privacy Notes

Depending on enabled features, the app can handle microphone audio, camera
frames, selected photos, location samples, calendar summaries, and journal
content.

- Audio and text are sent to the configured WebSocket backend.
- Vision mode sends recent camera frames as base64 JPEG conversation context to
  the configured backend while the mode is enabled.
- Journal entries, selected photo copies, and location samples are stored
  locally in the app's Application Support directory. They remain there until
  removed by the app/user or the app data is deleted.
- Journal mode can send conversation excerpts, slot progress, selected-photo
  counts, location sample counts, and optional calendar summaries to the
  configured backend as journal prompt context. The full journal entry is still
  generated and stored locally by the app.
- Selected photos are copied into app storage from the original image data and
  may retain metadata embedded in that image data.
- API keys entered in the app are stored in the iOS Keychain.

Do not use the app with a backend you do not trust.

## Third-Party Assets

The MotionPNGTuber player and bundled avatar assets are documented in:

```text
chat app/MotionPNGTuberPlayer/THIRD_PARTY_NOTICES.md
```

## License

No project-wide open source license is currently granted. Public GitHub access
allows viewing the repository, but reuse, redistribution, or derivative works
are not permitted unless a license is added later.
