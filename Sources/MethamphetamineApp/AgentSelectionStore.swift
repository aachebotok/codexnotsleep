import Foundation

@MainActor
final class AgentProtectionStore {
  private static let key = "agentSleepProtectionEnabled"
  private static let lowBatterySleepKey = "lowBatterySleepEnabled"
  private static let pendingPowerProtectKey = "pendingPowerProtectEnable"
  private static let legacySelectionKey = "enabledCodingAgentIDs"
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

  func loadLowBatterySleep(defaultValue: Bool = true) -> Bool {
    guard defaults.object(forKey: Self.lowBatterySleepKey) != nil else {
      return defaultValue
    }
    return defaults.bool(forKey: Self.lowBatterySleepKey)
  }

  func saveLowBatterySleep(_ isEnabled: Bool) {
    defaults.set(isEnabled, forKey: Self.lowBatterySleepKey)
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
