<p align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="Codex Not Sleep app icon">
</p>

<h1 align="center">Codex Not Sleep</h1>

<p align="center">
  A native macOS menu bar app that keeps your Mac awake only while Codex is working.
</p>

<p align="center">
  <strong>Version 1.0.0</strong> · macOS 13 or later
</p>

## Download

[Download Codex Not Sleep from GitHub Releases](https://github.com/aachebotok/codexnotsleep/releases)

Download the latest signed `.dmg`, open it, and drag **Codex Not Sleep** to the Applications folder. The first public build will appear on the Releases page after it has been signed and notarized.

## What it does

- Detects active Codex tasks automatically
- Prevents idle and system sleep only while Codex is working
- Optionally keeps tasks running when the MacBook lid is closed
- Smoothly dims the built-in display as the lid closes and restores the previous brightness as it opens
- Releases sleep protection when the last task finishes
- Restores protection if Codex starts working again
- Allows normal sleep when the battery reaches 10% or lower
- Runs locally with no account, analytics, or API connection

Codex Not Sleep lives entirely in the menu bar. Use the **Stay awake** switch to enable or disable automatic protection at any time.

> Keeping a Mac awake with its lid closed can use more battery and generate heat. Do not leave an active Mac inside a bag or another enclosed space.

## Privacy and permissions

Codex Not Sleep reads lifecycle markers from local Codex session files to determine when a task starts and finishes. It does not store or send your prompts, responses, or source code.

Closed-lid operation requires a one-time administrator confirmation. The app installs a narrow `sudoers` rule that permits only the two required `pmset` commands. Remove that rule with:

```bash
sudo rm /private/etc/sudoers.d/methamphetamine_power_protect_$(id -u)
```

## Build from source

Requirements: macOS 13 or later, Xcode, and a Swift 6 toolchain.

```bash
swift test
./scripts/package.sh
```

The packaging script creates an ad-hoc signed app at `dist/Codex Not Sleep.app`. Public releases must be signed with Developer ID and notarized by Apple.

See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidance and [SECURITY.md](SECURITY.md) for security reporting.
