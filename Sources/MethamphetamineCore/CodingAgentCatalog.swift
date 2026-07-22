public enum CodingAgentCatalog {
  public static let supported: [CodingAgentDefinition] = [
    CodingAgentDefinition(
      id: "codex",
      displayName: "Codex",
      bundleIdentifiers: ["com.openai.codex"],
      executableNames: ["codex"],
      excludedFirstArguments: ["app-server", "code-mode-host"],
      sortOrder: 0
    ),
    CodingAgentDefinition(
      id: "claude",
      displayName: "Claude Code",
      bundleIdentifiers: ["com.anthropic.claudefordesktop"],
      executableNames: ["claude"],
      sortOrder: 1
    ),
    CodingAgentDefinition(
      id: "cursor",
      displayName: "Cursor",
      bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
      executableNames: ["cursor-agent"],
      sortOrder: 2
    ),
    CodingAgentDefinition(
      id: "windsurf",
      displayName: "Devin",
      bundleIdentifiers: ["com.exafunction.windsurf"],
      executableNames: ["devin"],
      sortOrder: 3
    ),
    CodingAgentDefinition(
      id: "zed",
      displayName: "Zed Agent",
      bundleIdentifiers: ["dev.zed.Zed"],
      sortOrder: 4
    ),
    CodingAgentDefinition(
      id: "opencode",
      displayName: "OpenCode",
      bundleIdentifiers: [
        "ai.opencode.desktop",
        "ai.opencode.desktop.beta",
        "ai.opencode.desktop.dev",
      ],
      executableNames: ["opencode"],
      sortOrder: 5
    ),
    CodingAgentDefinition(
      id: "gemini",
      displayName: "Gemini CLI",
      executableNames: ["gemini"],
      sortOrder: 6
    ),
    CodingAgentDefinition(
      id: "copilot",
      displayName: "GitHub Copilot CLI",
      executableNames: ["copilot"],
      requiredExecutablePathFragments: [
        "/Caskroom/copilot-cli/",
        "/Caskroom/copilot-cli@prerelease/",
        "/node_modules/@github/copilot/",
      ],
      homeInstallationMarkers: [".copilot"],
      sortOrder: 7
    ),
    CodingAgentDefinition(
      id: "aider",
      displayName: "Aider",
      executableNames: ["aider"],
      sortOrder: 8
    ),
    CodingAgentDefinition(
      id: "kimi",
      displayName: "Kimi Code",
      executableNames: ["kimi"],
      sortOrder: 9
    ),
    CodingAgentDefinition(
      id: "qwen",
      displayName: "Qwen Code",
      bundleIdentifiers: ["com.alibaba.qwen-code"],
      executableNames: ["qwen"],
      sortOrder: 10
    ),
    CodingAgentDefinition(
      id: "grok",
      displayName: "Grok Build",
      executableNames: ["grok"],
      requiredExecutablePathFragments: ["/.grok/bin/grok"],
      homeInstallationMarkers: [".grok"],
      sortOrder: 11
    ),
    CodingAgentDefinition(
      id: "kiro",
      displayName: "Kiro",
      bundleIdentifiers: ["dev.kiro.desktop"],
      executableNames: ["kiro-cli"],
      sortOrder: 12
    ),
    CodingAgentDefinition(
      id: "antigravity",
      displayName: "Google Antigravity",
      bundleIdentifiers: ["com.google.antigravity", "com.google.antigravity-ide"],
      executableNames: ["agy"],
      sortOrder: 13
    ),
    CodingAgentDefinition(
      id: "amp",
      displayName: "Amp",
      executableNames: ["amp"],
      requiredExecutablePathFragments: [
        "/.amp/bin/amp",
        "/Cellar/ampcode/",
        "/node_modules/@ampcode/cli/",
        "/node_modules/@sourcegraph/amp/",
      ],
      sortOrder: 14
    ),
    CodingAgentDefinition(
      id: "auggie",
      displayName: "Auggie",
      executableNames: ["auggie"],
      sortOrder: 15
    ),
    CodingAgentDefinition(
      id: "cline",
      displayName: "Cline CLI",
      executableNames: ["cline"],
      sortOrder: 16
    ),
    CodingAgentDefinition(
      id: "continue",
      displayName: "Continue CLI",
      executableNames: ["cn"],
      requiredExecutablePathFragments: [
        "/.continue/bin/cn",
        "/node_modules/@continuedev/cli/",
      ],
      sortOrder: 17
    ),
    CodingAgentDefinition(
      id: "droid",
      displayName: "Factory Droid",
      executableNames: ["droid"],
      requiredExecutablePathFragments: ["/node_modules/droid/"],
      requiredCodeSigningTeamIdentifiers: ["SW6TL4V6Q5"],
      homeInstallationMarkers: [".factory"],
      sortOrder: 18
    ),
    CodingAgentDefinition(
      id: "goose",
      displayName: "Goose",
      bundleIdentifiers: ["com.block.goose", "com.electron.goose"],
      executableNames: ["goose"],
      homeInstallationMarkers: [
        ".config/goose",
        "Library/Application Support/Block/goose",
      ],
      sortOrder: 19
    ),
    CodingAgentDefinition(
      id: "vibe",
      displayName: "Mistral Vibe",
      executableNames: ["vibe", "vibe-acp"],
      requiredExecutablePathFragments: [
        "/mistral-vibe/",
        "/mistral_vibe/",
      ],
      sortOrder: 20
    ),
    CodingAgentDefinition(
      id: "junie",
      displayName: "Junie CLI",
      executableNames: ["junie"],
      sortOrder: 21
    ),
    CodingAgentDefinition(
      id: "kilo",
      displayName: "Kilo Code",
      executableNames: ["kilo"],
      requiredExecutablePathFragments: [
        "/.kilo/bin/kilo",
        "/.kilocode/bin/kilo",
        "/node_modules/@kilocode/cli/",
      ],
      sortOrder: 22
    ),
    CodingAgentDefinition(
      id: "crush",
      displayName: "Crush",
      executableNames: ["crush"],
      requiredExecutablePathFragments: [
        "/Cellar/crush/",
        "/node_modules/@charmland/crush/",
      ],
      homeInstallationMarkers: [".config/crush"],
      sortOrder: 23
    ),
    CodingAgentDefinition(
      id: "openhands",
      displayName: "OpenHands CLI",
      executableNames: ["openhands"],
      sortOrder: 24
    ),
    CodingAgentDefinition(
      id: "codebuddy",
      displayName: "CodeBuddy Code",
      executableNames: ["codebuddy"],
      sortOrder: 25
    ),
    CodingAgentDefinition(
      id: "codebuff",
      displayName: "Codebuff",
      executableNames: ["codebuff"],
      sortOrder: 26
    ),
    CodingAgentDefinition(
      id: "tabnine",
      displayName: "Tabnine CLI",
      executableNames: ["tabnine"],
      sortOrder: 27
    ),
    CodingAgentDefinition(
      id: "neovate",
      displayName: "Neovate Code",
      executableNames: ["neovate"],
      sortOrder: 28
    ),
    CodingAgentDefinition(
      id: "pochi",
      displayName: "Pochi",
      executableNames: ["pochi"],
      sortOrder: 29
    ),
    CodingAgentDefinition(
      id: "qoder",
      displayName: "Qoder CLI",
      executableNames: ["qodercli"],
      sortOrder: 30
    ),
    CodingAgentDefinition(
      id: "trae",
      displayName: "Trae Agent",
      bundleIdentifiers: ["com.trae.app"],
      executableNames: ["trae-cli"],
      sortOrder: 31
    ),
    CodingAgentDefinition(
      id: "pi",
      displayName: "Pi Coding Agent",
      executableNames: ["pi"],
      requiredExecutablePathFragments: [
        "/node_modules/@earendil-works/pi-coding-agent/",
        "/node_modules/@mariozechner/pi-coding-agent/",
      ],
      sortOrder: 32
    ),
    CodingAgentDefinition(
      id: "warp-oz",
      displayName: "Warp Oz",
      executableNames: ["oz", "oz-preview"],
      requiredExecutablePathFragments: [
        "/Caskroom/oz/",
        "/Caskroom/oz@preview/",
        "/Cellar/oz/",
        "/Oz.app/",
        "/Warp.app/",
        "/WarpPreview.app/",
        "/Warp Preview.app/",
      ],
      sortOrder: 33
    ),
  ]
}
