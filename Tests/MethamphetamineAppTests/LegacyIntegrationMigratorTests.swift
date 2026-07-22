import Foundation
import MethamphetamineCore
import Testing

@testable import MethamphetamineApp

@Suite
@MainActor
struct LegacyIntegrationMigratorTests {
  @Test
  func removesLegacyHookWithoutReplacingSettingsSymlink() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "Methamphetamine.LegacySymlinkTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: root) }

    let home = root.appending(path: "home", directoryHint: .isDirectory)
    let claudeDirectory = home.appending(path: ".claude", directoryHint: .isDirectory)
    let dotfilesDirectory = root.appending(path: "dotfiles", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: dotfilesDirectory, withIntermediateDirectories: true)

    let target = dotfilesDirectory.appending(path: "claude-settings.json")
    let link = claudeDirectory.appending(path: "settings.json")
    try legacyFixture(provider: "claude").write(to: target)
    try fileManager.createSymbolicLink(at: link, withDestinationURL: target)

    let migrator = LegacyIntegrationMigrator(homeDirectory: home)
    try migrator.remove(.claude)

    #expect(try fileManager.destinationOfSymbolicLink(atPath: link.path) == target.path)
    let updated = try Data(contentsOf: target)
    #expect(!LegacyHookConfiguration.containsIntegration(data: updated, integration: .claude))
    let backups = try fileManager.contentsOfDirectory(atPath: dotfilesDirectory.path)
      .filter { $0.contains("methamphetamine-backup") }
    #expect(backups.count == 1)
  }

  @Test
  func controllerMarksSuccessfulMigrationAndDoesNotRepeatIt() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "Methamphetamine.OneTimeMigrationTests.\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    defer { try? fileManager.removeItem(at: root) }
    let codexDirectory = root.appending(path: ".codex", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
    let configURL = codexDirectory.appending(path: "hooks.json")
    try legacyFixture(provider: "codex").write(to: configURL)

    let suiteName = "Methamphetamine.OneTimeMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: root, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: root),
      backend: FakeMigrationSleepProtectionBackend(),
      startsAutomatically: false
    )

    controller.migrateLegacyIntegrations()
    let firstBackupCount = try backupCount(in: codexDirectory, fileManager: fileManager)
    controller.migrateLegacyIntegrations()

    #expect(defaults.integer(forKey: "legacyHookMigrationVersion") == 2)
    #expect(try backupCount(in: codexDirectory, fileManager: fileManager) == firstBackupCount)
  }

  private func legacyFixture(provider: String) -> Data {
    Data(
      """
      {
        "theme": "dark",
        "hooks": {
          "Stop": [{
            "hooks": [{
              "type": "command",
              "command": "'/Applications/Methamphetamine.app/Contents/Helpers/meth-hook' --provider \(provider) --event Stop",
              "statusMessage": "methamphetamine-hook"
            }]
          }]
        }
      }
      """.utf8
    )
  }

  private func backupCount(in directory: URL, fileManager: FileManager) throws -> Int {
    try fileManager.contentsOfDirectory(atPath: directory.path)
      .count { $0.contains("methamphetamine-backup") }
  }
}

@MainActor
private final class FakeMigrationSleepProtectionBackend: SleepProtectionBackend {
  let identifier = "fake-migration"
  private(set) var isHeld = false

  func acquire() throws {
    isHeld = true
  }

  func renew() throws {}

  func release() {
    isHeld = false
  }
}
