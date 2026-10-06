# 👁 Glance Focus

**Look at a monitor — your cursor follows.**

Glance Focus is a tiny macOS menu bar app for multi-monitor setups. It uses your Mac's built-in camera to see which screen you're looking at and instantly moves the mouse cursor to that screen. No more dragging the cursor across two huge displays.

<!-- Demo: add a GIF here, e.g. ![demo](docs/demo.gif) -->

## Features

- **Hands-free screen switching.** Turn your head toward a monitor and the cursor jumps there.
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
7. Click the 👁 icon in the menu bar and enable **"Kompyuter yonganda avtomatik ishga tushsin"** (launch at login).

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
| Yoqilgan | Turn tracking on/off |
| Kalibrlash… | Run calibration again |
| Tezlik | Speed mode: Sekin / O'rta / Tez / Juda tez (bashoratli) |
| Oxirgi joyga qaytish | Jump to the last cursor position instead of the screen center |
| Kompyuter yonganda avtomatik ishga tushsin | Launch at login |
| Chiqish | Quit |

**Tips**

- Run calibration again if you change your seating position, move the camera, or rearrange your monitors.
- If the cursor jumps when you don't want it to, switch to **Tez** or **O'rta**.
- The app won't move the cursor while you are actively using the mouse.

## How it works

1. **Face tracking.** Apple's Vision framework detects your face in each camera frame and measures how far your head is turned left or right (yaw). It also measures where your pupils are inside your eyes.
2. **Calibration.** While you look at each screen, the app records your typical head/eye "signal" for that screen.
3. **Decision.** In every frame, the app picks the screen whose calibrated signal is closest to the current one. Smoothing, hysteresis and a short stability window prevent jitter.
4. **Prediction (optional).** In the predictive mode, the app estimates how fast your head is turning. If you're clearly turning toward another screen and are past about 55% of the way, it moves the cursor early.
5. **Cursor move.** The cursor is moved with `CGWarpMouseCursorPosition`.

Prediction can be tuned in `FocusController.swift` using `predictMinProgress`, `predictSpeedFactor`, `predictFrames` and `predictCooldown`.

## Troubleshooting

| Problem | Fix |
|---|---|
| Cursor doesn't move | System Settings → Privacy & Security → **Accessibility** → enable GlanceFocus |
| "Kameraga ruxsat yo'q" in the menu | System Settings → Privacy & Security → **Camera** → enable GlanceFocus |
| Calibration fails ("Yuz ko'rinmadi") | Improve the lighting and make sure your face is visible to the camera |
| Wrong screen is chosen | Run **Kalibrlash…** again from your normal sitting position |
| Unwanted jumps | Use **Tez** instead of **Juda tez (bashoratli)** |

## Project structure

```
GlanceFocus/
├── MyApp.swift              # App entry point + menu bar UI
├── FocusController.swift    # Camera, Vision tracking, calibration, prediction, cursor control
└── CalibrationOverlay.swift # Full-screen calibration overlay with the red dot
```

---

## 🇺🇿 O'zbekcha qisqacha

**Glance Focus** — qaysi monitorga qarasangiz, sichqoncha o'sha monitorga o'tadi. Ilova Mac kamerasi orqali boshingiz qaysi tomonga burilganini aniqlaydi.

**O'rnatish:**
1. [Releases](../../releases) sahifasidan `GlanceFocus.zip` ni yuklab oling va `GlanceFocus.app` ni Applications papkasiga o'tkazing.
2. Ilovani oching va "Apple tekshira olmadi" degan ogohlantirish chiqqanda **Done** ni bosing.
3. System Settings → Privacy & Security → pastga tushing → **Open Anyway** ni bosing.
4. Kameraga ruxsat bering va har bir monitordagi qizil nuqtaga qarab kalibratsiyadan o'ting.
5. Menu bar'dagi 👁 → "Kompyuter yonganda avtomatik ishga tushsin" ni belgilang.

Hamma hisob-kitob kompyuterning o'zida bajariladi: internetga hech narsa yuborilmaydi, rasmlar saqlanmaydi.

## License

[MIT](LICENSE)
