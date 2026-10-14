# TinyMixer

A tiny macOS menu bar app to set the volume of each app separately, without touching the system volume.

<img src="docs/screenshot.png" width="320" alt="TinyMixer menu">

## Features

- **Per-app volume and mute** for every app currently playing sound (Chrome, Spotify, a Slack huddle…).
- **Notifications & alerts** row, always shown: macOS plays every app's notification sound itself, Slack's included, so they can only be turned down together.
- Volumes are remembered per app and applied as soon as the app plays again.
- Optional launch at login.

## Build & run

Requires macOS 14.2+ and the Xcode Command Line Tools.

```sh
./build.sh && open build/TinyMixer.app
```

On first use macOS asks for **System Audio Recording** permission: it is needed to reroute an app's sound, nothing is recorded.

## How it works

For each app set below 100%, TinyMixer creates a Core Audio process tap that mutes the app's own output and plays the tapped audio back at the chosen volume. Apps at 100% are left untouched, and if TinyMixer quits every app's sound goes back to normal.

To silence only one app's notifications, turn off its sound in System Settings → Notifications.
