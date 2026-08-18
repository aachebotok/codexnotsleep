import Testing

@testable import CodexNotSleepCore

@Suite struct CodingAgentCatalogTests {
  @Test func catalogHasStableUniqueIdentifiersAndSignatures() {
    let definitions = CodingAgentCatalog.supported

    #expect(
      definitions.map(\.id) == [
        "codex",
        "claude",
        "cursor",
        "windsurf",
        "zed",
        "opencode",
        "gemini",
        "copilot",
        "aider",
        "kimi",
        "qwen",
        "grok",
        "kiro",
        "antigravity",
        "amp",
        "auggie",
        "cline",
        "continue",
        "droid",
        "goose",
        "vibe",
        "junie",
        "kilo",
        "crush",
        "openhands",
        "codebuddy",
        "codebuff",
        "tabnine",
        "neovate",
        "pochi",
        "qoder",
        "trae",
        "pi",
        "warp-oz",
      ])
    #expect(Set(definitions.map(\.id)).count == definitions.count)
    #expect(Set(definitions.map(\.sortOrder)).count == definitions.count)

    let bundleIdentifiers = definitions.flatMap(\.bundleIdentifiers)
    let executableNames = definitions.flatMap(\.executableNames)
    #expect(Set(bundleIdentifiers).count == bundleIdentifiers.count)
    #expect(Set(executableNames).count == executableNames.count)
    #expect(
      definitions.allSatisfy {
        !$0.bundleIdentifiers.isEmpty || !$0.executableNames.isEmpty
      })
  }

  @Test func catalogContainsExpectedCodexHelperExclusions() throws {
    let codex = try #require(CodingAgentCatalog.supported.first { $0.id == "codex" })

    #expect(codex.bundleIdentifiers == ["com.openai.codex"])
    #expect(codex.executableNames == ["codex"])
    #expect(codex.excludedFirstArguments == ["app-server", "code-mode-host"])
  }

  @Test func ambiguousExecutableRequiresVerifiedOrigin() throws {
    let amp = try #require(CodingAgentCatalog.supported.first { $0.id == "amp" })
    let copilot = try #require(CodingAgentCatalog.supported.first { $0.id == "copilot" })
    let droid = try #require(CodingAgentCatalog.supported.first { $0.id == "droid" })

    #expect(
      !amp.recognizesExecutable(
        named: "amp",
        canonicalPaths: ["/usr/local/bin/amp"]
      ))
    #expect(
      amp.recognizesExecutable(
        named: "amp",
        canonicalPaths: ["/Users/test/.amp/bin/amp"]
      ))
    #expect(
      droid.recognizesExecutable(
        named: "droid",
        canonicalPaths: ["/Users/test/.local/bin/droid"],
        codeSigningTeamIdentifier: "SW6TL4V6Q5"
      ))
    #expect(
      droid.recognizesExecutable(
        named: "droid",
        canonicalPaths: ["/Users/test/.local/bin/droid"],
        existingHomeMarkers: [".factory"]
      ))
    #expect(
      !droid.recognizesExecutable(
        named: "droid",
        canonicalPaths: ["/Users/test/.local/bin/droid"]
      ))
    #expect(
      !copilot.recognizesExecutable(
        named: "copilot",
        canonicalPaths: ["/usr/local/bin/copilot"]
      ))
    #expect(
      copilot.recognizesExecutable(
        named: "copilot",
        canonicalPaths: ["/usr/local/lib/node_modules/@github/copilot/index.js"]
      ))
  }

  @Test func currentDesktopProductSignaturesArePreserved() throws {
    let devin = try #require(CodingAgentCatalog.supported.first { $0.id == "windsurf" })
    let antigravity = try #require(
      CodingAgentCatalog.supported.first { $0.id == "antigravity" })
    let trae = try #require(CodingAgentCatalog.supported.first { $0.id == "trae" })
    let openCode = try #require(CodingAgentCatalog.supported.first { $0.id == "opencode" })

    #expect(devin.displayName == "Devin")
    #expect(devin.bundleIdentifiers == ["com.exafunction.windsurf"])
    #expect(devin.executableNames == ["devin"])
    #expect(
      antigravity.bundleIdentifiers == [
        "com.google.antigravity",
        "com.google.antigravity-ide",
      ])
    #expect(antigravity.executableNames == ["agy"])
    #expect(trae.bundleIdentifiers == ["com.trae.app"])
    #expect(
      openCode.bundleIdentifiers == [
        "ai.opencode.desktop",
        "ai.opencode.desktop.beta",
        "ai.opencode.desktop.dev",
      ])

    let warpOz = try #require(CodingAgentCatalog.supported.first { $0.id == "warp-oz" })
    #expect(warpOz.executableNames == ["oz", "oz-preview"])
  }
}
