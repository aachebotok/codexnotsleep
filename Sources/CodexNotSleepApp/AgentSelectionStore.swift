import Foundation

@MainActor
final class AgentProtectionStore {
  nonisolated static let key = "agentSleepProtectionEnabled"
  nonisolated static let pendingPowerProtectKey = "pendingPowerProtectEnable"
  nonisolated static let legacySelectionKey = "enabledCodingAgentIDs"
  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  var hasStoredPreference: Bool {
    defaults.object(forKey: Self.key) != nil
  }

  func load(defaultValue: Bool = false) -> Bool {
    if hasStoredPreference {
      return defaults.bool(forKey: Self.key)
    }
    if let legacyAgentIDs = defaults.stringArray(forKey: Self.legacySelectionKey) {
      return !legacyAgentIDs.isEmpty
    }
    return defaultValue
  }

  func save(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: Self.key)
  }

  var isPowerProtectSetupPending: Bool {
    defaults.bool(forKey: Self.pendingPowerProtectKey)
  }

  func markPowerProtectSetupPending() {
    defaults.set(true, forKey: Self.pendingPowerProtectKey)
  }

  func clearPowerProtectSetupPending() {
    defaults.removeObject(forKey: Self.pendingPowerProtectKey)
  }
}

struct LegacyPreferencesMigrator {
  static let legacyBundleIdentifier = "app.methamphetamine.Methamphetamine"
  static let migrationVersionKey = "methamphetaminePreferencesMigrationVersion"
  static let migrationVersion = 1

  private static let migratedKeys = [
    AgentProtectionStore.key,
    AgentProtectionStore.pendingPowerProtectKey,
    AgentProtectionStore.legacySelectionKey,
  ]

  private let defaults: UserDefaults
  private let legacyDefaults: UserDefaults?

  init(
    defaults: UserDefaults = .standard,
    legacyDefaults: UserDefaults? = UserDefaults(suiteName: Self.legacyBundleIdentifier)
  ) {
    self.defaults = defaults
    self.legacyDefaults = legacyDefaults
  }

  func migrate() {
    guard defaults.integer(forKey: Self.migrationVersionKey) < Self.migrationVersion else {
      return
    }

    if let legacyDefaults {
      for key in Self.migratedKeys where defaults.object(forKey: key) == nil {
        guard let value = legacyDefaults.object(forKey: key) else { continue }
        defaults.set(value, forKey: key)
      }
    }

    defaults.set(Self.migrationVersion, forKey: Self.migrationVersionKey)
  }
}
