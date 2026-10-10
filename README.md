# ulular

A small native macOS menu-bar app for switching your audio output and controlling its volume — including on monitors whose volume macOS can't change. Swift, AppKit, SwiftUI and Core Audio; no third-party dependencies and no virtual audio driver.

## Features

- **Output switcher:** pick any output device (built-in, Bluetooth, USB, HDMI/DisplayPort) from the menu bar. Alert sounds follow the selection.
- **Hardware volume and mute:** slider and mute button for devices that expose them, kept in sync with changes made elsewhere.
- **Software volume for monitors:** for outputs with no volume control, ulular taps the audio headed to the monitor and applies gain in a lock-free real-time callback, with a perceptual volume curve and click-free ramping. Remembered per device and restored after relaunch, device changes and sleep/wake.
- **Volume keys:** the keyboard volume and mute keys control software volume (Option+Shift for fine steps), with an on-screen volume card that also shows over full-screen video.
- **Menu-bar only:** no Dock icon, optional Start at Login.

## Requirements

- macOS 13 or newer (macOS 14.2+ for software volume)
- Xcode or command-line tools with Swift 5.9+

## Build

```sh
./scripts/build-app.sh
open dist/ulular.app
swift test
```

Software volume needs system-audio capture permission, and the volume keys need Accessibility permission. Turn the monitor's physical volume down before enabling software volume: when ulular stops processing audio, playback returns to full level.

Details, limitations and a manual test checklist are in [docs/GUIDE.md](docs/GUIDE.md).

## License

Apache License 2.0 — see [LICENSE](LICENSE).
