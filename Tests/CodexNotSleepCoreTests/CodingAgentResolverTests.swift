import Testing

@testable import CodexNotSleepCore

@Suite struct CodingAgentResolverTests {
  private let resolver = CodingAgentResolver()

  @Test func resolvesInstalledApplicationAndCLI() {
    let snapshot = CodingAgentSystemSnapshot(
      installedApplicationBundleIdentifiers: ["com.anthropic.claudefordesktop"],
      installedExecutableNames: ["gemini"]
    )

    let detected = resolver.resolve(snapshot)

    #expect(detected.map(\.id) == ["claude", "gemini"])
    #expect(detected.allSatisfy { $0.isInstalled })
    #expect(detected.allSatisfy { !$0.isRunning })
  }

  @Test func omitsUnknownAndUninstalledAgents() {
    let snapshot = CodingAgentSystemSnapshot(
      installedApplicationBundleIdentifiers: ["com.example.unrelated"],
      installedExecutableNames: ["unrelated"],
      runningApplicationBundleIdentifiers: ["com.example.running"],
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "unrelated",
          hasControllingTerminal: true
        )
      ]
    )

    #expect(resolver.resolve(snapshot).isEmpty)
  }

  @Test func deduplicatesApplicationAndCLIObservations() throws {
    let snapshot = CodingAgentSystemSnapshot(
      installedApplicationBundleIdentifiers: ["com.openai.codex"],
      installedExecutableNames: ["codex"],
      runningApplicationBundleIdentifiers: ["com.openai.codex"],
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: true
        ),
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: true
        ),
      ]
    )

    let detected = resolver.resolve(snapshot)
    let codex = try #require(detected.first)

    #expect(detected.count == 1)
    #expect(codex.id == "codex")
    #expect(codex.isInstalled)
    #expect(codex.isRunning)
  }

  @Test func signatureMatchingIsExact() {
    let snapshot = CodingAgentSystemSnapshot(
      installedApplicationBundleIdentifiers: ["com.openai.codex.helper"],
      installedExecutableNames: ["codex-helper", "/usr/local/bin/claude"],
      runningApplicationBundleIdentifiers: ["com.openai.codex.preview"],
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "codex-helper",
          hasControllingTerminal: true
        ),
        CodingAgentProcessObservation(
          executableName: "/usr/local/bin/claude",
          hasControllingTerminal: true
        ),
      ]
    )

    #expect(resolver.resolve(snapshot).isEmpty)
  }

  @Test func cliRequiresTTYAndRejectsExcludedHelpers() throws {
    let ignoredProcesses = CodingAgentSystemSnapshot(
      installedExecutableNames: ["codex"],
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: false
        ),
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: true,
          isExcludedHelper: true
        ),
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: true,
          isExcludedHelper: true
        ),
      ]
    )

    let installedCodex = try #require(resolver.resolve(ignoredProcesses).first)
    #expect(installedCodex.id == "codex")
    #expect(!installedCodex.isRunning)

    let interactiveProcess = CodingAgentSystemSnapshot(
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "codex",
          hasControllingTerminal: true
        )
      ]
    )
    let runningCodex = try #require(resolver.resolve(interactiveProcess).first)
    #expect(runningCodex.id == "codex")
    #expect(runningCodex.isInstalled)
    #expect(runningCodex.isRunning)
  }

  @Test func sortsRunningAgentsFirstThenUsesCatalogOrder() {
    let snapshot = CodingAgentSystemSnapshot(
      installedApplicationBundleIdentifiers: [
        "com.openai.codex",
        "com.anthropic.claudefordesktop",
      ],
      installedExecutableNames: ["gemini", "aider"],
      runningApplicationBundleIdentifiers: ["com.anthropic.claudefordesktop"],
      runningProcesses: [
        CodingAgentProcessObservation(
          executableName: "aider",
          hasControllingTerminal: true
        )
      ]
    )

    let detected = resolver.resolve(snapshot)

    #expect(detected.map(\.id) == ["claude", "aider", "codex", "gemini"])
    #expect(detected.map(\.isRunning) == [true, true, false, false])
  }
}
