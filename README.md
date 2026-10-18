# CapsLockSwitcher for macOS

[![macOS](https://img.shields.io/badge/macOS-13.0+-blue.svg)](https://www.apple.com/macos)
[![License](https://img.shields.io/badge/License-MIT-brightgreen.svg)](LICENSE.md)

**CapsLockSwitcher** is a lightweight macOS background agent that provides **instant, reliable switching between exactly two user-selected keyboard input sources (layouts) using the Caps Lock key**.

It's designed to overcome the common frustrations with the native macOS input switching behavior.

## Why CapsLockSwitcher?

Are you tired of:

1.  **The noticeable delay** (hundreds of milliseconds) when switching input sources using the standard macOS methods?
2.  The native "Use Caps Lock to switch..." setting **cycling through *all* your enabled layouts**, including the often unwanted "ABC" or U.S. layout, instead of just the two you frequently use?
3.  Accidentally activating the **actual Caps Lock state** (uppercase typing) when you just wanted to switch layouts?
4.  Layout switching that **silently stops working** until you restart some app or lock the screen?

CapsLockSwitcher solves these problems by providing a dedicated, fast, and targeted switching mechanism.

## Features

*   🚀 **Instant Switching:** Bypasses the standard macOS input source switching delay by remapping Caps Lock to a dedicated key at the HID level.
*   🎯 **User-Selectable Layouts:** Switches *only* between the two keyboard layouts you explicitly choose in its menu.
*   🔒 **Works under Secure Input:** Uses a system hot key (Carbon `RegisterEventHotKey`), which WindowServer keeps delivering while Secure Event Input is on. Event-tap based switchers go deaf whenever an app (a password field, a browser, an Electron app, or a stuck `loginwindow`) holds Secure Input.
*   🔠 **UPPERCASE when you want it:** Hold Caps Lock (0.4 s) or press Shift + Caps Lock to lock uppercase; press Caps Lock again to release it. Both options can be turned off in the menu.
*   🙅 **No permissions needed:** No Accessibility or Input Monitoring prompts.
*   🩹 **Self-healing:** Re-applies the Caps Lock remap after sleep, screen unlock or user switch, and checks it every 30 seconds. Reverts the remap synchronously on quit so Caps Lock is never left dead.
*   💡 **Lightweight & Native:** Runs as a background agent with no Dock icon. No kernel extensions or drivers.
*   🚦 **Status Bar Icon:** Shows the state (Active, Configuring, hot key unavailable) and whether Secure Input is currently on.
*   🚀 **Launch on Startup:** Optional setting to automatically start the app when you log in (macOS 13+ required).

## Installation

### Recommended

1.  Go to the [**Releases**](https://github.com/doasync/CapsLockSwitcher/releases) page of this repository. 
2.  Download the latest `.app` file.
3.  Copy `CapsLockSwitcher.app` to your `/Applications` folder.
4.  Launch `CapsLockSwitcher` from your Applications folder.
5.  Run `xattr -cr /Applications/CapsLockSwitcher.app` in the terminal

`xattr -cr /Applications/CapsLockSwitcher.app` removes extended attributes recursively (`-r`) and clears code signing attributes (`-c`) from the `CapsLockSwitcher.app` application. It's essentially stripping away the "downloaded from the internet" flags that macOS Gatekeeper uses to restrict the app's execution.

### Build from source (no Xcode needed)

```bash
./build.sh
ditto build/CapsLockSwitcher.app /Applications/CapsLockSwitcher.app
```

The script compiles a universal (arm64 + x86_64) app with the Command Line Tools and signs it ad hoc.

## Usage

1.  **Launch the App:** Double-click `CapsLockSwitcher` in your Applications folder. A new icon (⚠️ or ⌨️...) will appear in your menu bar.
2.  **Permissions:** None. Since 2.0 the app no longer needs Accessibility access.
3.  **Configure Layouts:**
    *   Once permissions are granted, the icon should change to ⌨️....
    *   Click the status bar icon.
    *   You will see a list of your currently enabled keyboard layouts.
    *   Click on the **first** layout you want to switch between. A checkmark will appear next to it. The status text will update (e.g., "Select 1 more layout...").
    *   Click on the **second** layout you want to switch between. Another checkmark will appear.
4.  **Activate Switching:**
    *   Once two layouts are selected, the status bar icon will change to ⌨️ (`keyboard.fill`), and the status text will show "Switcher: Active".
    *   **Press the Caps Lock key!** It will now instantly switch between the two layouts you selected.
    *   **Need uppercase?** Hold Caps Lock or press Shift + Caps Lock. Press Caps Lock again to turn it off.
5.  **(Optional) Launch on Startup:**
    *   Click the status bar icon.
    *   Select "Launch on Startup" to toggle the setting (requires macOS 13+). A checkmark indicates it's enabled.

## How it works

1.  `hidutil` remaps Caps Lock to the `LANG1` key (`0x700000090`), which macOS delivers as `kVK_JIS_Kana`. On non-Japanese layouts that key does nothing by itself, and it has none of the native Caps Lock delay.
2.  A Carbon hot key on `kVK_JIS_Kana` toggles between your two layouts with `TISSelectInputSource`. A second hot key with Shift, or holding the key, sets the real Caps Lock state through `IOHIDSetModifierLockState`.
3.  When you quit the app, Caps Lock is mapped back to itself.

## Troubleshooting

*   **Not Switching:**
    *   **Check Selection:** Click the icon. Ensure exactly two layouts have checkmarks next to them. Make sure the layouts you selected are still *enabled* in System Settings > Keyboard > Input Sources.
    *   **Hot key unavailable:** If the menu shows this, another app has grabbed the same key. Quit it, then reopen the menu to retry.
    *   **Restart the App:** Quit CapsLockSwitcher (via its menu) and relaunch it.
*   **Caps Lock does nothing after the app crashed:** Run `hidutil property --set '{"UserKeyMapping":[]}'` or simply relaunch the app.
