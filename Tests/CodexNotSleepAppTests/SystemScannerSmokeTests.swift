import AppKit
import Foundation
import CodexNotSleepCore
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct SystemScannerSmokeTests {
  @Test
  func scannerFindsKnownLocalInstallationsWithoutLaunchingAgents() {
    let agents = CodingAgentSystemScanner().detectAgents()
    let identifiers = Set(agents.map(\.id))
    let fileManager = FileManager.default

    if fileManager.fileExists(atPath: "/Applications/ChatGPT.app") {
      #expect(identifiers.contains("codex"))
    }
    if fileManager.fileExists(atPath: "/Applications/Claude.app") {
      #expect(identifiers.contains("claude"))
    }
  }

  @Test
  func executableSearchIgnoresAppResourcesAndProjectNodeModules() {
    let directories = ExecutableSearchPaths.directories(
      fileManager: .default,
      homeDirectory: URL(fileURLWithPath: "/tmp/codexnotsleep-test-home"),
      environment: [
        "PATH":
          "/Applications/ChatGPT.app/Contents/Resources:/tmp/project/node_modules/.bin:/tmp/codexnotsleep-test-home/.config/yarn/global/node_modules/.bin:/custom/bin"
      ]
    )
    let paths = Set(directories.map(\.path))

    #expect(!paths.contains("/Applications/ChatGPT.app/Contents/Resources"))
    #expect(!paths.contains("/tmp/project/node_modules/.bin"))
    #expect(
      paths.contains(
        "/tmp/codexnotsleep-test-home/.config/yarn/global/node_modules/.bin"))
    #expect(paths.contains("/custom/bin"))
    #expect(paths.contains("/tmp/codexnotsleep-test-home/.kimi-code/bin"))
    #expect(paths.contains("/tmp/codexnotsleep-test-home/.grok/bin"))
    #expect(paths.contains("/tmp/codexnotsleep-test-home/.cursor/bin"))
  }

  @Test
  func scannerRejectsAmbiguousCommandUntilProductMarkerExists() throws {
    let fileManager = FileManager.default
    let homeDirectory = fileManager.temporaryDirectory.appending(
      path: "CodexNotSleep.ScannerIdentityTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: homeDirectory) }

    let binaryDirectory = homeDirectory.appending(path: ".local/bin")
    let droidExecutable = binaryDirectory.appending(path: "droid")
    try fileManager.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: droidExecutable)
    try fileManager.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: droidExecutable.path
    )

    let droid = try #require(CodingAgentCatalog.supported.first { $0.id == "droid" })
    let scanner = CodingAgentSystemScanner(
      definitions: [droid],
      fileManager: fileManager,
      homeDirectory: homeDirectory,
      environment: [:]
    )

    #expect(scanner.detectAgents().isEmpty)

    try fileManager.createDirectory(
      at: homeDirectory.appending(path: ".factory"),
      withIntermediateDirectories: true
    )
    #expect(scanner.detectAgents(refreshInstallations: true).map(\.id) == ["droid"])
  }
}
