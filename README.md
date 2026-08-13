# Methamphetamine

Methamphetamine is a small macOS menu bar app that keeps your Mac awake while Codex is working. It detects active Codex tasks automatically, prevents sleep while they run, and allows your Mac to sleep again when they finish.

## Download

[Download the latest version for macOS](https://github.com/mishanaer/Methamphetamine/releases/latest/download/Methamphetamine.dmg)

Open the DMG, then drag Methamphetamine to Applications. Requires macOS 13 or later.

## How it works

- Keeps Codex running when your Mac would normally go to sleep
- Can keep tasks running when the lid is closed
- Turns sleep protection off when the last task finishes
- Restores protection if the task starts working again
- Allows sleep at 10% battery or below
- Runs locally with no account or API connection

Methamphetamine requires macOS 13 or later. Keeping a Mac awake with the lid closed can use more battery and generate heat, so do not leave it running inside a bag.

## Privacy and permissions

Methamphetamine reads lifecycle markers from local Codex session files to know when a task starts and finishes. It does not store or send your prompts, responses, or code.

Keeping a Mac awake with the lid closed requires a one-time administrator confirmation. This installs a narrow `sudoers` rule that allows only the two required `pmset` commands. To remove the rule:

```bash
sudo rm /private/etc/sudoers.d/methamphetamine_power_protect_$(id -u)
```

## Build

```bash
swift test
swift build -c release
./scripts/package.sh
```

The packaging script creates a local ad-hoc signed app in `dist/`. Public releases must be signed with Developer ID and notarized by Apple.
