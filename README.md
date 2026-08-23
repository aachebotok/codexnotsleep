<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Codexetine app icon">
</p>

<h1 align="center">Codexetine</h1>

<p align="center">
  A native macOS menu bar app that keeps your Mac awake only while Codex is working.
</p>

<p align="center">
  <strong>Version 1.0.0</strong> · macOS 13 or later
</p>

## Download

[Download Codexetine from GitHub Releases](https://github.com/aachebotok/codexnotsleep/releases/latest)

Download the latest `.dmg`, open it, and drag **Codexetine** to the Applications folder.

### Upgrading from Codex Not Sleep

Codexetine keeps the historical bundle identifier so existing preferences and
login-item registration can continue to work. If **/Applications/Codex Not Sleep.app**
is still present, the first launch of the installed Codexetine app shows a
native migration prompt. Choose **Move Old App to Trash** only after confirming
the old copy is no longer running; **Later** leaves it untouched. The migration
does not remove preferences, closed-lid leases, sudoers configuration, or the
current Codexetine login item.

### If macOS blocks the app

The current release is locally signed but not notarized by Apple, so Gatekeeper may show a message saying that Apple could not verify the app for malicious software. To open it:

1. Make sure **Codexetine.app** has been copied from the DMG to the **Applications** folder.
2. Open the app from **Applications**.
3. In the warning, click **Done**. Do not move the app to the Trash.
4. Open **System Settings → Privacy & Security**.
5. Scroll to **Security** and click **Open Anyway** next to the message about Codexetine.
6. Confirm with your password, then click **Open**.

If **Open Anyway** is not visible, try opening the app from **Applications** again, dismiss the warning with **Done**, then close and reopen System Settings. macOS shows this option for about one hour after the blocked launch. See [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/mh40616/mac).

## What it does

- Detects active Codex tasks automatically
- Adds itself to Login Items on first launch from the Applications folder
- Prevents idle and system sleep only while Codex is working
- Optionally keeps tasks running when the MacBook lid is closed
- Smoothly dims the built-in display and keyboard backlight below 45° as the lid closes, then restores both to their previous brightness at 45°
- Releases sleep protection when the last task finishes
- Restores protection if Codex starts working again
- Allows normal sleep when the battery reaches 10% or lower
- Runs locally with no account, analytics, or API connection

Codexetine lives entirely in the menu bar. Use the native **Stay Awake** menu item to enable or disable automatic protection at any time. The stable **Keep Awake with Lid Closed** item controls the optional closed-lid layer; setup and sleep-recovery actions appear only when needed.

Ordinary open-lid protection uses macOS's native sleep assertion and does not
require administrator approval. The stable **Keep Awake with Lid Closed** menu
item appears separately with a native checkmark; it requests the one-time
closed-lid setup only when you enable that feature.

> Keeping a Mac awake with its lid closed can use more battery and generate heat. Do not leave an active Mac inside a bag or another enclosed space.

## Privacy and permissions

Codexetine reads lifecycle markers from local Codex session files to determine when a task starts and finishes. It does not store or send your prompts, responses, or source code.

Closed-lid operation requires a one-time administrator confirmation. The app
installs a narrow `sudoers` rule that permits only the two required `pmset`
commands. The historical filename is retained so existing installations can be
recovered and removed. Remove that rule with:

```bash
sudo rm /private/etc/sudoers.d/methamphetamine_power_protect_$(id -u)
```

## Build from source

Requirements: macOS 13 or later, Xcode, and a Swift 6 toolchain.

```bash
swift test
swift build -c release
./scripts/package.sh
```

The packaging script creates a universal, ad-hoc signed app at `dist/Codexetine.app` and DMG at `dist/Codexetine-1.0.0.dmg`. Public releases must be signed with Developer ID and notarized by Apple.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance and [SECURITY.md](SECURITY.md) for security reporting.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the event-driven monitoring, sleep-state ownership, and brightness recovery invariants.
