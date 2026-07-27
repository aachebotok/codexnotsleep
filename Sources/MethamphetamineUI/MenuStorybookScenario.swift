@MainActor
struct MenuStorybookScenario: Identifiable {
  let id: String
  let title: String
  let note: String
  let state: MenuContentState

  static let all: [MenuStorybookScenario] = [
    .init(
      id: "disabled",
      title: "Off",
      note: "Mac sleeps normally",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "waiting",
      title: "Waiting",
      note: "Protection is on, but no tasks are active",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "protected",
      title: "Codex is working",
      note: "Your Mac will stay awake",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "grace",
      title: "Task completed",
      note: "Short pause before allowing sleep",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "low-battery",
      title: "Low battery",
      note: "Your Mac may sleep at 10% or below",
      state: .init(
        isProtectionEnabled: true,
        isPreparingProtection: false,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "preparing",
      title: "Setup",
      note: "Waiting for system confirmation",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: true,
        issue: nil,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "permission",
      title: "Permission required",
      note: "To keep your Mac running with the lid closed",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .permissionRequired,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "restore",
      title: "Sleep wasn't re-enabled",
      note: "Mac stays awake after the task completes",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .sleepRestoreRequired,
        isResolvingIssue: false
      )
    ),
    .init(
      id: "restoring",
      title: "Restoring sleep",
      note: "Restoring normal sleep settings",
      state: .init(
        isProtectionEnabled: false,
        isPreparingProtection: false,
        issue: .sleepRestoreRequired,
        isResolvingIssue: true
      )
    ),
  ]
}
