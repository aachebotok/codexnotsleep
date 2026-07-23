import AppKit
import Foundation
import MethamphetamineCore
import SwiftUI
import Testing

@testable import MethamphetamineApp

@Suite
@MainActor
struct MenuContentViewLayoutTests {
  @Test
  func menuKeepsOneToggleInEveryProtectionState() throws {
    let suiteName = "Methamphetamine.MenuLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let fixtureHome = FileManager.default.temporaryDirectory.appending(
      path: "Methamphetamine.MenuLayoutTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let disabledController = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: LayoutTestSleepProtectionBackend(),
      startsAutomatically: false
    )
    let disabledSize = NSHostingView(
      rootView: MenuContentView(controller: disabledController)
    ).fittingSize

    defaults.set(true, forKey: "agentSleepProtectionEnabled")
    let enabledController = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: LayoutTestSleepProtectionBackend(),
      startsAutomatically: false
    )
    let enabledSize = NSHostingView(
      rootView: MenuContentView(controller: enabledController)
    ).fittingSize

    #expect(enabledSize == disabledSize)
  }

  @Test
  func detectedAgentsDoNotAddIndividualRows() throws {
    let suiteName = "Methamphetamine.MenuLayoutTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let fixtureHome = FileManager.default.temporaryDirectory.appending(
      path: "Methamphetamine.MenuLayoutTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
      backend: LayoutTestSleepProtectionBackend(),
      startsAutomatically: false
    )
    let emptySize = NSHostingView(
      rootView: MenuContentView(controller: controller)
    ).fittingSize

    controller.detectedAgents = [
      agent(id: "codex", name: "Codex", running: true),
      agent(id: "claude", name: "Claude Code", running: false),
      agent(id: "kimi", name: "Kimi Code", running: false),
    ]

    let detectedSize = NSHostingView(
      rootView: MenuContentView(controller: controller)
    ).fittingSize

    #expect(detectedSize == emptySize)
  }

  private func agent(id: String, name: String, running: Bool) -> DetectedCodingAgent {
    let definition = CodingAgentDefinition(
      id: id,
      displayName: name,
      executableNames: [id],
      sortOrder: 0
    )
    return DetectedCodingAgent(
      definition: definition,
      isInstalled: true,
      isRunning: running
    )
  }
}

@MainActor
private final class LayoutTestSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "layout-test"
  private(set) var isHeld = false

  func acquire() throws {
    isHeld = true
  }

  func renew() throws {}

  func release() {
    isHeld = false
  }
}
