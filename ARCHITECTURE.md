# Codex Not Sleep architecture

Codex Not Sleep is a native macOS 13+ menu-bar utility with one narrow job:
keep the Mac awake while Codex has active work, then restore ordinary sleep
behavior. It does not display, persist, or transmit transcript contents and it
does not manage other coding agents.

## Runtime topology

```text
Codex Not Sleep.app
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
│   └── 30-second serialized reconciliation
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
`CodexActivitySnapshot` values back to the main actor. A 30-second
`DispatchSourceTimer` is retained only as a recovery path for dropped events,
sleep/wake, startup while Codex is already running, and recreated session
directories. It is not the normal activity loop.

`SleepProtectionWorker` owns a separate serial utility queue for IOPM,
`pmset`, `sudo`, AppleScript, lease, watchdog, and other blocking backend
operations. Results are delivered to `AppController` on the main actor in
submission order.

## Native menu-bar UI

The primary UI is an `NSStatusItem` backed by an `NSMenu`. The normal menu has
a native checkable `Stay Awake` item, followed by `Quit Codex Not Sleep` with
Command-Q. Setup or recovery actions are inserted only when an issue requires
user action. AppKit owns menu geometry, highlighting, keyboard navigation,
accessibility, and sizing; there is no custom SwiftUI popover or manual anchor
positioning.

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

The FSEvents observer watches the Codex session root and reports file changes,
including dropped-event flags that force discovery on the next refresh. The
locator uses `sysctl`/`libproc` and file-descriptor inspection to distinguish a
live Codex runtime from stale historical sessions and to discover sessions
that are not currently held open by a descriptor. Those checks occur at
startup, on event-driven refreshes when correlation is needed, and on the
serialized reconciliation path; there is no one-second full scan loop.

The monitor keeps bounded per-file state: file identity, committed offset,
up to 4 KiB of a partial final line, current turn identity, minimal lifecycle
metadata, and bounded liveness timestamps. It reads appended data in bounded
chunks, resets safely on truncation/replacement, and discards processed JSON.
Historical reverse bootstrap is capped at 64 MiB.

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
off the main actor. The installer uses a fixed command path, exact arguments,
sanitized environment, an atomic root-owned `0440` temporary file, and
`visudo` validation.

The closed-lid backend records an app-owned lease token and runs a watchdog
only while that lease is active. It detects inherited `SleepDisabled` state
before acquisition and never disables a global state it did not create.
Stale app-owned leases are recovered on startup. Partial activation and
release failures preserve the lease and expose a bounded recovery action.
The historical `Methamphetamine` Application Support directory, preference
keys, hook marker, sudoers filename, and backup extension remain only where
they are needed to migrate or recover existing installations.

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
opening, task completion, protection disable, reset, and quit.

## Battery and login behavior

Battery status is read at protection decisions in the production coordinator,
on a utility queue, rather than polled every second. At or below 10 percent
while running on battery, protection is released. Unknown capacity and
external power do not trigger that safeguard.

Launch-at-login uses `SMAppService.mainApp` where the app is installed in a
supported location. Development, DMG, approval-required, already-enabled,
revoked, and registration-failure paths are handled without recurring work.

## Compatibility and cleanup

The old generalized coding-agent catalog, resolver, process scanner, agent
selection UI, and storybook were not used by the Codex runtime and are no
longer part of the target. The global preference store retains the old
`enabledCodingAgentIDs` key only as a one-time migration input. Legacy hook
removal and closed-lid lease recovery remain because existing installations
can still contain those states.

## Testing and performance claims

Policy, parser, monitor, brightness, launch-at-login, migration, and sleep
backend behavior are covered by deterministic tests. Native menu geometry and
physical HID/display behavior require manual validation on a real Mac.

The architecture removes the former one-second full scanner and permanent
60 Hz lid timer. Exact CPU, memory, wakeup, and battery improvements require
measurement and are not inferred from this design alone.
