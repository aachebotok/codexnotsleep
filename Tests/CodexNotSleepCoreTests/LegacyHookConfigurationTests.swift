import Foundation
import Testing

@testable import CodexNotSleepCore

@Suite
struct LegacyHookConfigurationTests {
  @Test
  func removalPreservesOtherIntegrationsAndUnrelatedSettings() throws {
    let original = fixtureData()
    let withoutCodex = try LegacyHookConfiguration.removing(data: original, integration: .codex)
    let root = try #require(JSONSerialization.jsonObject(with: withoutCodex) as? [String: Any])
    let text = String(decoding: withoutCodex, as: UTF8.self)

    #expect(root["theme"] as? String == "dark")
    #expect(text.contains("existing.sh"))
    #expect(!LegacyHookConfiguration.containsIntegration(data: withoutCodex, integration: .codex))
    #expect(LegacyHookConfiguration.containsIntegration(data: withoutCodex, integration: .claude))
  }

  @Test
  func removalRequiresBothMarkerAndProvider() throws {
    let withoutClaude = try LegacyHookConfiguration.removing(
      data: fixtureData(), integration: .claude)
    let text = String(decoding: withoutClaude, as: UTF8.self)

    #expect(text.contains("foreign-helper --provider claude"))
    #expect(!LegacyHookConfiguration.containsIntegration(data: withoutClaude, integration: .claude))
    #expect(LegacyHookConfiguration.containsIntegration(data: withoutClaude, integration: .codex))
  }

  @Test
  func userConfigurationPathsUseInjectedHome() {
    let fixtureHome = URL(fileURLWithPath: "/tmp/codexnotsleep-fixture-home", isDirectory: true)

    #expect(
      IntegrationConfigurationPaths.url(for: .codex, homeDirectory: fixtureHome).path
        == "/tmp/codexnotsleep-fixture-home/.codex/hooks.json")
    #expect(
      IntegrationConfigurationPaths.url(for: .claude, homeDirectory: fixtureHome).path
        == "/tmp/codexnotsleep-fixture-home/.claude/settings.json")
  }

  private func fixtureData() -> Data {
    Data(
      """
      {
        "theme": "dark",
        "hooks": {
          "PostToolUse": [
            {
              "hooks": [
                {"type": "command", "command": "existing.sh"},
                {"type": "command", "command": "'/Applications/Methamphetamine.app/Contents/Helpers/meth-hook' --provider codex", "statusMessage": "methamphetamine-hook"},
                {"type": "command", "command": "'/Applications/Methamphetamine.app/Contents/Helpers/meth-hook' --provider claude", "statusMessage": "methamphetamine-hook"},
                {"type": "command", "command": "foreign-helper --provider claude", "statusMessage": "methamphetamine-hook"},
                {"type": "command", "command": "foreign-helper --provider claude", "statusMessage": "another-product"}
              ]
            }
          ]
        }
      }
      """.utf8
    )
  }
}
