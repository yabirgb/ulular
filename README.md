# MusicTask

A native macOS menu-bar app for selecting your audio output and controlling its volume. Built with Swift, AppKit, SwiftUI, and Core Audio. No third-party dependencies or virtual audio driver.

## Requirements

- macOS 13 Ventura or newer for device selection and hardware volume
- **macOS 14.2 or newer** for optional process-tap software volume
- Xcode or the Xcode command-line tools with Swift 5.9 or newer to build

## Build and launch

```sh
./scripts/build-app.sh
open dist/MusicTask.app
```

Quit any previously running copy before launching a new build. Click the speaker icon in the menu bar. Select an output, drag the volume slider, or click the small speaker button to mute/unmute. The power button quits the app. Clicking outside the panel closes it. MusicTask does not appear in the Dock.

To install, copy `dist/MusicTask.app` into `/Applications`. For launch at login, add it under **System Settings → General → Login Items**.

For development, open `Package.swift` in Xcode, or run `swift build`. For software-volume testing, use the bundled `.app` rather than `swift run`, so macOS can read its audio-capture permission description.

## Software volume for monitors

For an output without a writable hardware volume control, click **Enable Software Volume…** and confirm. Allow system-audio capture when macOS requests it. If necessary, check **System Settings → Privacy & Security → Screen & System Audio Recording** (the wording can vary by macOS version), then quit and reopen MusicTask.

**Turn down the monitor's physical volume before trying this. Stopping, quitting, sleep, disconnects, or changing devices/formats can restore unattenuated playback, which may be much louder.** MusicTask cannot preserve its attenuation when it is not processing audio.

The first activation starts at 25% on the slider. The slider uses a perceptual (cubic) taper, so equal slider movements sound like roughly equal loudness changes: 25% is about −36 dB and 50% about −18 dB. Once enabled, MusicTask remembers software volume **per device UID**, including its last volume level and mute state. It restores the route when the app reopens with that monitor selected, when you return to that output, and after sleep/wake. It does not change the default output on launch or automatically enable software volume for unfamiliar monitors. Clicking **Stop** disables automatic activation for that monitor; simply quitting preserves it.

While active, the slider and mute button control MusicTask's gain, not the monitor's hardware. macOS's own volume sliders do not control this gain. Preferences use the explicit `com.musictask.app` defaults domain for both bundled and development runs.

### Keyboard volume keys

Keyboard controls now accompany software volume automatically unless you explicitly disable them. Grant MusicTask permission under **System Settings → Privacy & Security → Accessibility**, using **Grant Keyboard Access…** if needed. MusicTask remembers your choice across launches and activates controls whenever software volume starts. While waiting for access, it checks silently every two seconds; no second button click is needed once permission becomes available. If macOS requires restarting the app, quit and reopen MusicTask—the remembered monitor and keyboard controls should restore. Click **Disable** (or **Cancel** while waiting) to turn off automatic keyboard controls; **Enable Keyboard Controls…** turns them back on.

If keys worked before rebuilding but stop afterward, the new ad-hoc signature may invalidate Accessibility authorization. Remove the old MusicTask entry from Accessibility and add the exact `.app` you are launching again. Avoid running multiple copies or switching between `/Applications` and `dist` builds.

MusicTask handles volume up/down and mute even when its panel is closed. Each volume press moves the slider by 1/16; holding **Option + Shift** uses 1/64 steps. Held volume keys repeat; mute does not. Handled keys show a macOS-style volume card (device name and level) in the top-right corner, including over full-screen video. MusicTask draws its own card because the macOS 26 system card reads the device's hardware volume and would always show 100% for a monitor. The card is display-only, not draggable. Option + a volume key without Shift is passed through to macOS, which opens Sound settings.

Only volume media-key events are consumed. Other keys are left alone, and keyboard interception is removed when software volume stops, including output changes and quitting. It is restored automatically when software volume restarts, unless you explicitly disabled keyboard controls. F-keys configured as standard function keys may require holding Fn/Globe to send volume events. Other keyboard-remapping apps may conflict with this feature.

### Routing

```text
Applications targeting selected monitor
    → device-scoped process tap (excluding MusicTask)
    → gain adjustment
    → selected physical monitor
```

A private aggregate device combines the tap input and monitor output on one clock. One real-time C callback applies a lock-free gain value with a short smoothing ramp; there is no additional application playback queue. `.mutedWhenTapped` suppresses the original playback only while the tap is being read. The system default output stays on the physical monitor; the private aggregate is not exposed in MusicTask's picker.

Audio stays on the Mac: it is not recorded, saved, or transmitted. There is still capture/output buffering, so **latency is not zero and has not been measured on your monitor**. The smoothing ramp is not an audio delay buffer.

### Current limitations

- Supports **stereo, output-only** devices, such as typical HDMI/DisplayPort monitors. Multichannel outputs and devices with input channels are rejected by this first implementation.
- Requires matching 32-bit float PCM stream formats; incompatible formats are rejected rather than silently played incorrectly. If your monitor is configured for surround sound, choose stereo in **Audio MIDI Setup**.
- Only audio targeting the selected device/stream is tapped. Apps routed elsewhere are unaffected; protected content and unusual routing may not be capturable.
- Permission behavior, mute behavior, lip-sync, and device compatibility require testing on real hardware. Automated gain tests do not validate the complete Core Audio route.
- The route is destroyed on stop, device switch/disconnect, sleep, format change, and normal quit. Saved monitors restore on relaunch, output selection/reconnection, and wake; an explicit Stop disables that restoration. Format changes can still require manual re-enabling. Failed automatic activation is attempted once per device selection rather than repeatedly prompting or rebuilding.

## Hardware-volume behavior

- Lists devices with output channels, including connected Bluetooth, USB, HDMI, and virtual audio outputs.
- Changes the system's **default audio output**. Apps explicitly choosing another device may not follow it. The separate system output used for notification/alert sounds is changed to the same device, so those sounds follow the selection (and are attenuated by software volume when it is active). Only devices chosen from MusicTask's picker are affected; if you later change the Sound Effects output in System Settings, it is not re-synced.
- Uses master volume when available; otherwise adjusts writable output-channel controls together. The slider displays their average; adjusting it sets those channels to the same level.
- Tracks external changes to selection, volume, mute, and connected devices with Core Audio property listeners.
- This is output volume, not a per-app mixer.

## Tests

```sh
swift test
```

Tests cover gain attenuation, stereo preservation, planar input conversion, mute changes, missing input, invalid gains, prevention of amplification, the perceptual volume curve, preference persistence across new instances, per-device settings, explicit disable preferences, and one-time migration of settings saved by older versions.

### Manual verification

1. Confirm the menu-bar icon appears without a Dock icon.
2. Select built-in speakers; test hardware volume, mute, and external setting changes.
3. Select a stereo HDMI/DisplayPort monitor; lower its physical volume first.
4. Enable software volume; approve capture permission. Test denied permission separately.
5. Play ordinary music/video; check for doubled audio, feedback, crackles, and lip-sync. Confirm slider and mute work. Enable keyboard controls, grant Accessibility access, then test volume up/down, holding a key, mute, and Option+Shift fine adjustments with the panel both open and closed. Confirm MusicTask's volume card appears top-right (also over full-screen video) with the same level as the panel (muted icon and empty bar when muted), and that Option + a volume key opens Sound settings. Verify unrelated keys still work and hardware volume keys resume normal behavior after software mode stops.
6. Stop software volume; confirm normal playback returns and the route disappears from Audio MIDI Setup. Expect unattenuated volume.
7. Re-enable; switch outputs, disconnect the monitor, change its format, and sleep/wake. Confirm software mode stops safely and saved monitors restore on reselection/reconnection/wake.
8. Quit while active; confirm normal playback returns. Relaunch with the same monitor selected should restore the route, last volume/mute, and keyboard controls without clicking Enable. Explicitly Stop, then relaunch; that monitor should remain off.

## Distribution

The build script produces an app for the current Mac's architecture and signs it ad hoc for local use. Distribution requires appropriate Developer ID signing/notarization. Ad-hoc signatures can change between builds, so macOS may request capture permission again.
