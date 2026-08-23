import Foundation

@MainActor
final class ProtectionPreferenceStore {
  nonisolated static let key = "agentSleepProtectionEnabled"
  nonisolated static let closedLidKey = "closedLidProtectionEnabled"
  nonisolated static let pendingPowerProtectKey = "pendingPowerProtectEnable"
  // Retained only to migrate the old per-agent preference to the global toggle.
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

  func loadClosedLidEnabled() -> Bool {
    defaults.bool(forKey: Self.closedLidKey)
  }

  func saveClosedLidEnabled(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: Self.closedLidKey)
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
  // Existing installations still use the renamed app's preference domain.
  static let legacyBundleIdentifier = "app.methamphetamine.Methamphetamine"
  // Retained so preference migration remains one-time and idempotent.
  static let migrationVersionKey = "methamphetaminePreferencesMigrationVersion"
  static let migrationVersion = 1

  private static let migratedKeys = [
    ProtectionPreferenceStore.key,
    ProtectionPreferenceStore.pendingPowerProtectKey,
    // Migration compatibility for the old per-agent selection key.
    ProtectionPreferenceStore.legacySelectionKey,
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
