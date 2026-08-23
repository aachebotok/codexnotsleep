# Codexetine contributor guide

## Read first

- Treat this file as stable project policy, not a replacement for source and tests.
- Read `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, and the code you touch.
- Read `ARCHITECTURE.md` before changing monitoring, concurrency, sleep protection, closed-lid behavior, brightness, recovery, persistence, or migration.
- Preserve unrelated work in a dirty tree. Never discard user changes just to make tests pass.
- Prefer the smallest design that satisfies verified requirements.

## Product boundary

Codexetine is a native macOS 13+ menu-bar utility with one primary job:

> Keep the Mac awake while Codex is actively working, then reliably restore normal system sleep behavior afterward.

The app runs locally and must not collect, persist, or transmit Codex transcript content.

Current intended behavior includes:

- automatic Codex task detection;
- menu-bar-only UI;
- enable/disable control;
- ordinary idle/system sleep prevention while Codex works;
- optional closed-lid support;
- low-battery safety behavior;
- launch at login where supported;
- smooth built-in display and keyboard-backlight dimming as the lid closes below the configured angle;
- restoration of normal brightness and sleep behavior afterward.

Do not expand the product into a general coding-agent manager unless that becomes an explicit product decision.

## Engineering priorities

When trade-offs conflict, use this order:

1. Never corrupt or incorrectly restore system sleep state.
2. Never let a genuinely active Codex task sleep because of an optimization regression.
3. Never modify an unrelated display or externally-owned `SleepDisabled` state.
4. Reliable crash/restart recovery.
5. Minimal idle CPU, wakeups, and battery impact.
6. Bounded memory use.
7. Native unobtrusive macOS UX.
8. Small maintainable architecture.
9. Cosmetic cleanup.

Correctness and recovery precede micro-optimization.

## Repository map

- `Sources/CodexNotSleepApp/`: native menu-bar integration, main-actor coordination, serial monitoring/system workers, and platform providers.
- `Sources/CodexNotSleepCore/`: policy and core domain types.
- `Tests/`: unit and regression tests.
- `scripts/`: packaging and release helpers.
- `Resources/`: metadata and assets.
- `ARCHITECTURE.md`: actual event-driven runtime topology and safety invariants.
- `README.md`: user-facing behavior and build instructions.
- `ARCHITECTURE.md`: architecture and invariants.
- `Sources/CodexNotSleepApp/BoundedProcessRunner.swift`: bounded local command execution.
- `Sources/CodexNotSleepApp/GraceDeadlineScheduler.swift`: one-shot policy grace deadlines.

If the tree changes, update this map.

## UI rules

- Keep the application menu-bar-only.
- Prefer `NSStatusItem`, `NSMenu`, and `NSMenuItem` for the primary interface.
- Do not build a custom SwiftUI popover merely to imitate a normal menu.
- Let macOS own menu spacing, highlighting, keyboard navigation, accessibility, and sizing.
- Keep the status icon visually consistent with system menu-bar items.
- Do not force oversized point sizes or heavy symbol weights without a demonstrated need.
- `Quit` should behave like a normal menu command and support Command-Q where appropriate.

## Codex monitoring invariants

- Normal monitoring should be event-driven.
- FSEvents should be the primary trigger for relevant Codex session-file changes when reliable.
- Known session-file changes should be handled from cached correlation without a global
  process/FD scan; correlation is a recovery/discovery path.
- Use incremental JSONL processing; do not repeatedly reread whole transcripts.
- Do not retain or log prompts, responses, source code, or arbitrary transcript bodies.
- Keep only minimal lifecycle metadata and bounded partial-line state.
- JSON lifecycle parsing must be semantic, not dependent on exact key order or whitespace.
- Process/FD inspection may be used strategically for correlation, startup, and recovery.
- Do not continuously enumerate all processes, file descriptors, or session files at 1 Hz without a proven correctness requirement.
- A rare reconciliation scan is acceptable as a recovery mechanism.
- Reconciliation must not overlap with itself and repeated requests should coalesce.
- Multiple simultaneous active Codex tasks must keep protection active until the last one finishes.
- Stale historical sessions must not keep the Mac awake indefinitely.
- Reconciliation backs off while the runtime is reliably idle and remains shorter only
  while activity is active or uncertain.
- FSEvents start recovery uses the finite fast sequence `[1, 2, 4, 8, 16, 30]`
  seconds, then a rare cooldown retry; fallback reconciliation remains active
  while the source is unhealthy, and the worker does not bypass the observer's
  retry owner.
- Stop clears pending event changes, locator inventory/discovered paths, and
  monitor session state. A new monitoring generation rejects stale callbacks
  and snapshots from the previous start.
- Uncertainty may protect conservatively for a bounded recovery window, but not forever.

## Concurrency invariants

- UI/presentation state belongs on `MainActor`.
- Blocking filesystem, process, `sysctl`, `libproc`, `pmset`, `sudo`, or parsing work must not run synchronously on `MainActor`.
- Prefer one clearly-owned monitor actor or serial worker over detached-task sprawl.
- Overlapping refreshes/reconciliations must be serialized or generation-ordered.
- Stale asynchronous results must not overwrite newer state.
- Monitoring callbacks and snapshots carry an explicit start generation so a
  Stop→Start cycle cannot reapply results from the previous runtime.
- Avoid `@unchecked Sendable` unless unavoidable and explicitly justified.
- Keep Swift 6 concurrency diagnostics clean.

## Sleep-protection invariants

### Normal open-lid operation

- Use the native IOPM assertion mechanism.
- Hold an assertion only while policy requires protection, such as an active Codex task or intentional grace period.
- Do not hold the assertion during ordinary idle app lifetime.
- Verify behavior with `pmset -g assertions` when changing this boundary.

### Closed-lid operation

- Closed-lid support is optional and may use privileged `pmset` state.
- Normal open-lid protection must work without administrator privileges.
- Privileged setup must be narrowly scoped and have essentially zero runtime cost while unused.
- The optional `Keep Awake with Lid Closed` action is the only normal path that requests
  administrator setup; ordinary open-lid IOPM protection must remain independent.
- Never broaden sudo privileges for convenience.
- External termination uses synchronous bounded best-effort brightness and
  backend cleanup; only the graceful menu Quit path waits for asynchronous
  brightness completion.

Critical invariant:

> Never restore or disable a global `SleepDisabled` state that Codexetine did not create.

Preserve or strengthen lease ownership, inherited-state detection, stale-lease recovery, rollback, release/recovery behavior, and watchdog recovery where needed.

## Watchdog and sudoers

If the watchdog remains:

- it exists only while the app owns closed-lid protection;
- it validates lease ownership;
- it handles stale PID/PID reuse safely;
- it uses safe paths, permissions, quoting, and cleanup;
- it does not become a permanent daemon.

Sudoers setup must use exact trusted executable paths, exact minimal arguments, no broad wildcards, safe temporary-file handling, atomic installation, root ownership, mode `0440`, `visudo` validation, and a sanitized environment.

## Lid brightness invariants

Do not remove the useful lid-angle brightness behavior unless product scope explicitly changes.

Desired behavior:

- while Codex protection is active and the lid closes below the configured angle, smoothly dim the built-in display;
- dim keyboard backlight where supported;
- restore the user's prior values when opening again or when protection ends.

Resource rules:

- no permanent 60 Hz timer merely because Codex is active;
- prefer IOHID input callbacks or another event-driven lid-angle source;
- a short-lived interpolation timer is acceptable only during an actual visual transition;
- when the lid is stationary, there should be no high-frequency polling or repeated brightness writes;
- if event delivery needs recovery, use rare reconciliation rather than continuous polling.

Display safety:

- brightness operations must target the correct built-in display;
- never fall back to an arbitrary first display;
- if reliable display mapping is unavailable, fail the brightness feature safely rather than touching an unrelated display.

Private API use must be isolated behind narrow providers and fail without breaking core sleep protection.

## Battery behavior

- Preserve the low-battery safety threshold unless intentionally changed.
- Avoid high-frequency battery polling; use power-source notifications and a cached status.
- Prefer efficient power-source notifications where practical.
- Low-battery policy must release the appropriate protection state reliably.

## Legacy naming and migration

The project was renamed from Methamphetamine. The only retained old identifiers must
be one-shot preference migration or recovery of app-owned privileged sleep state.

Do not blindly remove or rename old identifiers. Classify each remaining legacy identifier as:

1. migration compatibility;
2. stale-state recovery compatibility;
3. accidental leftover.

Keep compatibility-sensitive paths/keys where existing installations rely on them. Add a brief comment for intentionally retained legacy identifiers.
- The migration controller is strongly owned by the application delegate and
  keeps delayed recycle bookkeeping alive until its completion.

## Performance rules

This app is intended to remain resident for long periods.

Ideal idle model:

```text
OS event
→ small bounded amount of work
→ process sleeps again
```

Avoid timer-driven scan loops when an OS event can wake the process.

Search changed code for `Timer`, `DispatchSourceTimer`, repeated `Task.sleep`, polling loops, repeated process enumeration, repeated directory enumeration, and repeated HID reads. Every recurring mechanism must have a concrete correctness reason. The only recurring timers allowed by the current design are the one-shot grace/reconciliation timers and the short interpolation timer during an actual lid transition.

Do not make quantitative battery/performance claims without measurement.

## Memory/privacy rules

- Never retain full Codex transcripts.
- Keep buffers bounded.
- Discard processed JSON bytes.
- Remove stale per-session state.
- Bound logs and diagnostic history.
- Close file handles and process pipes.
- Stop observers/timers/streams deterministically.
- Never log private transcript content.

## Editing workflow

1. Record `git status --short` and inspect unrelated local changes.
2. Trace concrete behavior through source and existing tests.
3. For a confirmed defect, add or update a deterministic regression test when practical.
4. Make the smallest coherent change that restores the invariant or implements the requested behavior.
5. Run focused tests.
6. Review `git diff` and `git diff --check`.
7. Run the full suite before claiming completion.
8. Package and launch the real `.app` when runtime behavior changed.
9. Report anything not genuinely tested.

Do not refactor adjacent code merely because it could be prettier.

## Standard commands

```sh
swift test
swift build -c release
./scripts/package.sh
git diff --check
```

When sleep behavior changes, also inspect:

```sh
pmset -g assertions
```

## Publication boundary

Do not push, publish, tag, create a release, or open a pull request without explicit approval.

For substantial changes:

1. implement locally;
2. run tests/build/package;
3. provide a packaged `.app` for manual testing;
4. wait for explicit approval;
5. only then publish the exact tested revision.

If source changes after manual approval, re-run validation and disclose the difference before publishing.

## Definition of done

- Requested behavior is implemented without weakening system-state safety.
- Confirmed defects have regression coverage where practical.
- Event-driven paths do not silently regress into high-frequency polling.
- Privacy and migration behavior are preserved.
- Focused tests and full tests pass.
- Release build and packaging pass.
- Runtime behavior is manually checked when applicable.
- Performance claims are measured or clearly labeled as architectural expectations.
- Unverified hardware/closed-lid behavior is reported honestly.
- No push/PR/release occurs before explicit approval.
