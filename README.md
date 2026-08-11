# Attention

Personal Spotify-style iPhone app for listening to [Attention](https://www.attention.com/) call recordings. Home-screen name: **Attention**.

## Requirements

- Xcode 26.6+
- iOS 26.5 Simulator runtime (Xcode → Settings → Components)
- An **org-level** Attention API (application programming interface) key  
  Settings → API Keys in [app.attention.tech](https://app.attention.tech)  
  Media download requires org-level auth; a personal key will list calls but fail playback.

## Run on the iPhone Simulator

```bash
open AttentionCallPlayer.xcodeproj
```

Or from Terminal once the simulator runtime is installed:

```bash
xcrun simctl list devices available
xcodebuild -project AttentionCallPlayer.xcodeproj -scheme AttentionCallPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16' build
xcrun simctl boot "iPhone 16" || true
open -a Simulator
xcodebuild -project AttentionCallPlayer.xcodeproj -scheme AttentionCallPlayer \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -derivedDataPath build \
  build
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/AttentionCallPlayer.app
xcrun simctl launch booted com.extend.attentioncallplayer
```

On first launch, paste your org-level Attention API key. It is stored in the Keychain only.

## Features

- Library with pagination, hide-internal filter, date range, Continue Listening
- Search by title / participant email
- Background audio, lock-screen controls, speed, AirPlay
- Synced transcript with word highlight, tap-to-seek, speaker chapters
- Offline downloads (keeps last 20), up-next queue
- Smart silence skip, call details, snippets, Ask Attention
