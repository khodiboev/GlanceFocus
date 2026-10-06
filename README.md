# 👁 Glance Focus

**Look at a monitor — your cursor follows.**

Glance Focus is a tiny macOS menu bar app for multi-monitor setups. It uses your Mac's built-in camera to see which screen you're looking at, moves the mouse cursor to that screen, and can frost the screens you're not looking at so you stay focused.

<!-- Demo: add a GIF here, e.g. ![demo](docs/demo.gif) -->

## Features

- **Hands-free screen switching.** Turn your head toward a monitor and the cursor jumps there.
- **Frosted glass ❄️.** Screens you're not looking at blur like a frozen window and thaw the moment you look back. Use it together with cursor switching or on its own.
- **Four speed modes.** Choose between Slow (most stable), Medium, Fast, and Very fast (predictive). The predictive mode moves the cursor *before* your head finishes turning.
- **One-time calibration.** Look at a red dot on each screen for 2 seconds. Calibration is saved and reused.
- **Launch at login.** Turn it on once and forget about it.
- **Center or last position.** The cursor can jump to the center of the screen, or back to where it was last time on that screen.
- **Private by design.** All processing happens on-device with Apple's Vision framework. No network access, no images saved, and the camera turns off when the screen is locked or the Mac sleeps.
- **Lightweight.** It is a native Swift app with no third-party dependencies.

## Requirements

- macOS 14.6 (Sonoma) or later
- A Mac with a camera (built-in or external)
- Two or more monitors placed **side by side** (left/right)

> Monitors stacked vertically (one above the other) are not supported yet.

## Installation (no coding needed)

1. Go to the [**Releases**](../../releases) page and download `GlanceFocus.zip`.
2. Unzip it and drag **GlanceFocus.app** into your **Applications** folder.
3. Open the app. macOS will warn that it "cannot verify the developer", because the app is not notarized by Apple. Click **Done**.
4. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to GlanceFocus.
5. Click **Allow** when the app asks for camera access.
6. Follow the calibration: look at the red dot on each screen until it disappears.
7. Click the 👁 icon in the menu bar and turn on **Launch at login**.

If **Open Anyway** doesn't appear, run this in Terminal and open the app again:

```bash
xattr -cr /Applications/GlanceFocus.app
```

## Build from source

1. Clone the repository and open the project:

   ```bash
   git clone https://github.com/khodiboev/GlanceFocus.git
   cd GlanceFocus
   open GlanceFocus.xcodeproj
   ```

2. In Xcode, select the **GlanceFocus** target, then go to **Signing & Capabilities**:
   - Set **Team** to your own Apple ID (a free *Personal Team* works).
   - Change the **Bundle Identifier** to something unique, e.g. `com.yourname.GlanceFocus`.

3. Press **⌘R** to build and run.

To make a standalone app, choose **Product → Archive → Distribute App → Custom → Copy App**, then move the exported `GlanceFocus.app` to `/Applications`.

## Usage

Click the 👁 icon in the menu bar to open the menu:

| Menu item | What it does |
|---|---|
| Enabled | Turn tracking on or off |
| Calibrate… | Run calibration again |
| Speed | Slow (most stable), Medium, Fast, or Very fast (predictive) |
| Move cursor | Move the cursor to the screen you look at |
| Frosted glass ❄️ | Blur the screens you're not looking at |
| Return to last cursor position | Jump back to where the cursor was on that screen instead of its center |
| Launch at login | Start Glance Focus automatically |
| Quit | Quit the app |

**Tips**

- Run calibration again if you change your seating position, move the camera, or rearrange your monitors.
- If the cursor jumps when you don't want it to, switch to **Fast** or **Medium**.
- The app won't move the cursor while you are actively using the mouse.

## How it works

1. **Face tracking.** Apple's Vision framework detects your face in each camera frame and measures how far your head is turned left or right (yaw). It also measures where your pupils are inside your eyes.
2. **Calibration.** While you look at each screen, the app records your typical head/eye "signal" for that screen.
3. **Decision.** In every frame, the app picks the screen whose calibrated signal is closest to the current one. Smoothing, hysteresis and a short stability window prevent jitter.
4. **Prediction (optional).** In the predictive mode, the app estimates how fast your head is turning. If you're clearly turning toward another screen and are past about 55% of the way, it moves the cursor early.
5. **Action.** The cursor is moved with `CGWarpMouseCursorPosition`, and the other screens are covered with a click-through `NSVisualEffectView` that blurs whatever is behind it.

Prediction can be tuned in `FocusController.swift` using `predictMinProgress`, `predictSpeedFactor`, `predictFrames` and `predictCooldown`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Cursor doesn't move | System Settings → Privacy & Security → **Accessibility** → enable GlanceFocus |
| "No camera access" in the menu | System Settings → Privacy & Security → **Camera** → enable GlanceFocus |
| Calibration fails ("Face not detected") | Improve the lighting and make sure your face is visible to the camera |
| Wrong screen is chosen | Run **Calibrate…** again from your normal sitting position |
| Unwanted jumps | Use **Fast** instead of **Very fast (predictive)** |
| Text is still readable through the frost | The blur strength depends on macOS; see `FrostOverlay.swift` to tune the frost layer |

## Project structure

```
GlanceFocus/
├── MyApp.swift              # App entry point + menu bar UI
├── FocusController.swift    # Camera, Vision tracking, calibration, prediction, cursor control
├── CalibrationOverlay.swift # Full-screen calibration overlay with the red dot
└── FrostOverlay.swift       # Frosted glass effect for the screens you're not looking at
```

## License

[MIT](LICENSE)
