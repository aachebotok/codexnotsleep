# Codexetine architecture

Codexetine is a native macOS 13+ menu-bar utility with one narrow job:
keep the Mac awake while Codex has active work, then restore ordinary sleep
behavior. It does not display, persist, or transmit transcript contents and it
does not manage other coding agents.

## Runtime topology

```text
Codexetine.app
├── NSStatusItem + NSMenu
├── AppController (@MainActor)
│   ├── SleepPolicyMachine
│   ├── CodexActivityWorker
│   ├── SleepProtectionWorker
│   └── launch-at-login, battery, and brightness coordination
├── CodexSessionActivityMonitor
│   ├── FSEvents session-file observer
│   ├── incremental JSONL lifecycle state
│   ├── strategic process/FD correlation
│   └── adaptive serialized reconciliation
└── sleep and brightness providers
    ├── IOPM idle-sleep assertion
    ├── optional pmset closed-lid backend
    └── IOHID/private brightness providers
```

There is one application process. The project has no persistent helper daemon
or IPC boundary.

## Main-actor boundary

`AppController` owns presentation and policy state: the enabled preference,
current phase, setup/recovery issue, and the desired brightness state. It does
not perform live session inspection or blocking privileged work synchronously
in the production path.

`CodexActivityWorker` owns a serial utility queue. It starts and stops the
FSEvents source, coalesces refresh requests, and sends small
`CodexActivitySnapshot` values back to the main actor. Reconciliation is a
one-shot recovery timer: healthy stable idle uses 30 minutes, known active work
uses five minutes, and unhealthy or uncertain visibility uses 30 seconds. It
is re-armed after every refresh. If a bounded lifecycle read leaves a
committed backlog, the worker immediately coalesces another pass through the
known-file cache; that continuation does not enumerate processes or file
descriptors. It is not the normal activity loop.

`SleepProtectionWorker` owns a separate serial utility queue for IOPM,
`pmset`, `sudo`, AppleScript, lease, watchdog, and other blocking backend
operations. Results are delivered to `AppController` on the main actor in
submission order. The external `applicationWillTerminate` path is the narrow
exception: it calls a dedicated fast-release API directly, which only attempts
the non-privileged IOPM assertion release and never enters this queue.

## Native menu-bar UI

The primary UI is an `NSStatusItem` backed by an `NSMenu`. The normal menu has
a native checkable `Stay Awake` item, a stable checkable `Keep Awake with Lid
Closed` item, and `Quit` with Command-Q. Closed-lid setup is requested only
when that preference is enabled; ordinary IOPM protection does not require
administrator setup.
Setup or recovery actions are inserted only when an issue requires user action.
AppKit owns menu geometry, highlighting, keyboard navigation, accessibility,
and sizing; there is no custom SwiftUI popover or manual anchor positioning.

The status image is a template SF Symbol using normal status-item sizing. The
application uses the accessory activation policy and does not create a Dock
window.

## Codex monitoring

The live flow is:

```text
Codex changes ~/.codex/sessions
→ FSEvents callback
→ coalesced monitor refresh
→ relevant session/process correlation
→ bounded incremental JSONL update
→ minimal active-task snapshot
→ policy evaluation
```

The FSEvents observer watches the Codex session root with file events and root
watch enabled. One dedicated queue owns stream creation, start, stop,
invalidate, release, restart, and health state. Dropped or root-change flags
force discovery on the next refresh. A failed start marks the source unhealthy
and uses the finite fast retry sequence `1, 2, 4, 8, 16, 30` seconds. After
those attempts are exhausted, the same observer owner schedules a rare five
minute cooldown retry while the worker uses the 30-second fallback cadence;
the worker never starts a second observer or bypasses that backoff. A later
successful start cancels the slow retry and returns the worker to its normal
adaptive cadence. Once a session is known, a file event updates the cached
inventory and the monitor reads the appended bytes without a global process/FD
scan. The locator uses
`sysctl`/`libproc` and file-descriptor inspection when discovering a runtime,
recovering from an invalidated cache, or running scheduled safety
reconciliation. Candidate paths are capped at 256 and expire after 30 minutes;
historical date partitions are pruned before descent and enumeration is capped
at 2,048 entries. There is no one-second full scan loop.

Stopping monitoring cancels both retry phases, clears pending event paths and
full-scan flags, invalidates the cached inventory and discovered paths, and
resets the monitor's bounded per-session state. Each worker start receives a
new monitoring generation; callbacks and snapshots from an earlier generation
are discarded, so the first refresh after a new start discovers the current
runtime rather than trusting the previous one.

The monitor keeps bounded per-file state: file identity, committed offset,
up to 64 KiB of a partial final line, current turn identity, minimal lifecycle
metadata, and bounded liveness timestamps. It reads appended data in 512 KiB
chunks, immediately requeues committed backlog, resets safely on
truncation/replacement, and discards processed JSON. Records above the
supported 64 KiB line limit are explicitly classified as oversized and cause a
bounded conservative state. Reverse bootstrap retains the complete supported
line budget plus its newline across chunk boundaries; historical reverse
bootstrap and the final-newline search are capped at 64 MiB.

Lifecycle parsing uses semantic JSON parsing rather than raw byte patterns or
key order. It accepts `task_started`, `turn_started`, `task_complete`,
`turn_complete`, and `turn_aborted` in the expected `event_msg` envelope.
Unknown JSON is irrelevant; malformed lifecycle-shaped input produces a
bounded conservative state. Prompts, responses, source code, and arbitrary
transcript bodies are never retained or logged.

An active task protects the Mac. Multiple active tasks keep protection until
the last one completes. A completed last task enters the configured policy
grace period, then releases. Stale historical sessions do not keep protection
forever. Uncertain visibility may protect conservatively, but the monitor
uses bounded liveness windows and reconciliation before settling to idle.

## Sleep protection and ownership

Ordinary open-lid protection uses an IOPM assertion and exists only while the
policy requires protection. It is not held during an idle application
lifetime. The native assertion backend is combined with the optional closed-
lid backend; failure to set up closed-lid support does not remove ordinary
open-lid protection.

Closed-lid support uses narrowly authorized `/usr/bin/pmset` commands through
the historical UID-specific sudoers filename. Setup verifies the exact rule
semantically (metadata and both permitted commands) off the main actor. The
installer uses a fixed command path, exact arguments, sanitized environment,
an atomic root-owned `0440` temporary file, and `visudo` validation. All local
commands use a bounded process runner with capped stdout/stderr and timeout
cleanup; watchdog readiness is also bounded.

The closed-lid backend records an app-owned lease token and runs a watchdog
only while that lease is active. The watchdog waits for EOF on an inherited
parent pipe, validates the lease token, and attempts restoration with a finite
backoff budget; the parent PID is diagnostics only. It detects inherited
`SleepDisabled` state before acquisition and never disables a global state it
did not create. Stale app-owned leases are recovered on startup. Partial
activation and release failures preserve the ordinary IOPM assertion and
expose a targeted optional recovery action. Closed-lid preference migration
uses semantic setup validity only when the new preference key is absent.
The historical `Methamphetamine` Application Support directory and
UID-specific sudoers filename remain only for safe recovery of an app-owned
lease from an older installation. The old preference domain, migration
version key, and `enabledCodingAgentIDs` remain only for one-time preference
migration.

## Lid-angle brightness

While protection is active, `IOKitLidAngleSensor` receives lid-angle input
callbacks from the matching Apple HID device. Matching/removal callbacks
handle device reattachment and loss; the next device event performs a fresh
read. The sensor is stopped when brightness control stops or the app resets.

The controller captures the built-in display and keyboard values only when it
first needs to modify them. At or above 45 degrees it restores the captured
values. Below 45 degrees it computes display and keyboard targets and uses a
short 150 ms interpolation timer only while a transition is active. The timer
is invalidated when the transition reaches its target; a stationary open lid
does not create a recurring timer, HID read, or brightness write.

Display Services receives the exact built-in `CGDirectDisplayID`. If the
private API or reliable built-in display mapping is unavailable, brightness
control disables itself without touching an arbitrary external display. Such
failures do not affect sleep protection. Previous values are restored on lid
opening, task completion, protection disable, reset, and quit. Display and
keyboard restoration are independent and use a finite one-shot retry budget;
sleep protection does not depend on brightness success.

The menu Quit path may await that finite brightness budget before terminating.
The external `applicationWillTerminate` path cannot await a later callback, so
it performs one synchronous best-effort brightness restore and the dedicated
fast IOPM release. It does not run the normal privileged `pmset` sequence or
wait behind queued worker work; the app-owned closed-lid lease and watchdog
remain the recovery path. No delayed cleanup task is started during process
termination.

## Battery and login behavior

Battery status is cached and invalidated by IOKit power-source notifications;
the coordinator reevaluates on a notification or another meaningful policy
event rather than polling every second. At or below 10 percent while running
on battery, protection is released. Unknown capacity and external power do not
trigger that safeguard.

Launch-at-login uses `SMAppService.mainApp` where the app is installed in a
supported location. Development, DMG, approval-required, already-enabled,
revoked, and registration-failure paths are handled without recurring work.

## Compatibility and cleanup

The old generalized coding-agent catalog, resolver, process scanner, agent
selection UI, hook integration, and storybook were not used by the Codex
runtime and are no longer part of the target. The global preference store
retains the old `enabledCodingAgentIDs` key and old preference domain only as a
one-time migration input. Closed-lid lease recovery remains because existing
installations can still contain app-owned global `SleepDisabled` state.

## Testing and performance claims

Policy, parser, monitor, brightness, launch-at-login, migration, and sleep
backend behavior are covered by deterministic tests. Native menu geometry and
physical HID/display behavior require manual validation on a real Mac. The
opt-in FSEvents A/B test reports latency, callback count, and process CPU; the
current environment does not expose per-test wakeup or energy data, so those
fields are reported as unavailable rather than inferred.

The architecture removes the former one-second full scanner and permanent
60 Hz lid timer. Exact CPU, memory, wakeup, and battery improvements require
measurement and are not inferred from this design alone.
