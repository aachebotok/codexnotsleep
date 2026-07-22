import Foundation
import MethamphetamineCore

final class LegacyIntegrationMigrator {
  private let homeDirectory: URL

  init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) {
    self.homeDirectory = homeDirectory
  }

  func isInstalled(_ integration: IntegrationKind) -> Bool {
    let data = try? Data(contentsOf: resolvedConfigurationURL(for: integration))
    return LegacyHookConfiguration.containsIntegration(data: data, integration: integration)
  }

  func remove(_ integration: IntegrationKind) throws {
    let url = resolvedConfigurationURL(for: integration)
    guard let original = try? Data(contentsOf: url) else { return }
    let updated = try LegacyHookConfiguration.removing(data: original, integration: integration)
    guard updated != original else { return }

    try backup(original, for: url)
    let permissions = try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    try updated.write(to: url, options: [.atomic])
    if let permissions {
      try? FileManager.default.setAttributes(
        [.posixPermissions: permissions], ofItemAtPath: url.path)
    }
  }

  private func configurationURL(for integration: IntegrationKind) -> URL {
    IntegrationConfigurationPaths.url(for: integration, homeDirectory: homeDirectory)
  }

  private func resolvedConfigurationURL(for integration: IntegrationKind) -> URL {
    configurationURL(for: integration).resolvingSymlinksInPath()
  }

  private func backup(_ data: Data, for url: URL) throws {
    let safeDate = ISO8601DateFormatter().string(from: .now).replacing(":", with: "-")
    let backupURL = url.appendingPathExtension("methamphetamine-backup-\(safeDate)")
    try data.write(to: backupURL, options: [.atomic])
  }
}
