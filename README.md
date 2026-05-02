# Taggle

Lightweight macOS menu bar app to toggle an external display on/off with a keyboard shortcut.

Useful when you share a monitor between two machines (e.g. Mac on HDMI + PC on DVI) — prevents macOS from splitting your workspace across a display you're not actually looking at.

## Build & Run

```bash
bash build.sh
open build/Taggle.app
```

Optionally install to Applications:

```bash
cp -r build/Taggle.app /Applications/
```

## Usage

- Click the menu bar icon to select your target display and toggle it
- Default shortcut: **Cmd+Shift+F1**
- Change the shortcut via **Change Shortcut...** in the menu
- Settings persist across sessions

## Requirements

- macOS 11+
- Xcode Command Line Tools (`xcode-select --install`)
- Accessibility permission (System Settings > Privacy & Security > Accessibility)

## How it works

Uses the private CoreGraphics API `CGSConfigureDisplayEnabled` to programmatically enable/disable a display. No external dependencies, no network calls — everything runs locally.
