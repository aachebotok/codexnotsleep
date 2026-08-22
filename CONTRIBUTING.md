# Contributing

Contributions are welcome.

1. Fork the repository and create a branch.
2. Make a focused change with tests when possible.
3. Run `swift test`.
4. Run `swift build -c release` and `./scripts/package.sh` for runtime or packaging changes.
5. Open a pull request explaining what changed and why.

Codex Not Sleep requires macOS 13 or later and a Swift 6 toolchain.

The primary UI is a native `NSStatusItem`/`NSMenu`; avoid pixel-geometry tests for the menu. See [ARCHITECTURE.md](ARCHITECTURE.md) for monitoring, sleep-state ownership, and brightness invariants.
