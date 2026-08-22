import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct ProtectionPreferenceStoreTests {
  @Test
  func missingPreferenceStartsDisabledAndPersistsExplicitChoice() throws {
    let suiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = ProtectionPreferenceStore(defaults: defaults)
    #expect(!store.hasStoredPreference)
    #expect(!store.load())

    store.save(true)

    let restoredStore = ProtectionPreferenceStore(defaults: defaults)
    #expect(restoredStore.hasStoredPreference)
    #expect(restoredStore.load())
  }

  @Test
  func legacyAgentSelectionMapsToGlobalPreference() throws {
    let suiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = ProtectionPreferenceStore(defaults: defaults)

    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")
    #expect(store.load())

    defaults.set([], forKey: "enabledCodingAgentIDs")
    #expect(!store.load())
  }

  @Test
  func globalPreferenceOverridesLegacySelection() throws {
    let suiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let store = ProtectionPreferenceStore(defaults: defaults)

    #expect(!store.load())
  }

  @Test
  func migratesPreferencesFromPreviousBundleIdentifierOnce() throws {
    let currentSuiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.current.\(UUID().uuidString)"
    let legacySuiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.legacy.\(UUID().uuidString)"
    let currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
    let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    legacyDefaults.set(true, forKey: ProtectionPreferenceStore.key)
    legacyDefaults.set(true, forKey: ProtectionPreferenceStore.pendingPowerProtectKey)
    legacyDefaults.set(["codex"], forKey: ProtectionPreferenceStore.legacySelectionKey)

    let migrator = LegacyPreferencesMigrator(
      defaults: currentDefaults,
      legacyDefaults: legacyDefaults
    )
    migrator.migrate()

    #expect(currentDefaults.bool(forKey: ProtectionPreferenceStore.key))
    #expect(currentDefaults.bool(forKey: ProtectionPreferenceStore.pendingPowerProtectKey))
    #expect(currentDefaults.stringArray(forKey: ProtectionPreferenceStore.legacySelectionKey) == ["codex"])

    legacyDefaults.set(false, forKey: ProtectionPreferenceStore.key)
    migrator.migrate()
    #expect(currentDefaults.bool(forKey: ProtectionPreferenceStore.key))
  }

  @Test
  func migrationDoesNotOverwriteCurrentPreferences() throws {
    let currentSuiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.current.\(UUID().uuidString)"
    let legacySuiteName = "CodexNotSleep.ProtectionPreferenceStoreTests.legacy.\(UUID().uuidString)"
    let currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
    let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    currentDefaults.set(false, forKey: ProtectionPreferenceStore.key)
    legacyDefaults.set(true, forKey: ProtectionPreferenceStore.key)

    LegacyPreferencesMigrator(
      defaults: currentDefaults,
      legacyDefaults: legacyDefaults
    ).migrate()

    #expect(currentDefaults.object(forKey: ProtectionPreferenceStore.key) != nil)
    #expect(!currentDefaults.bool(forKey: ProtectionPreferenceStore.key))
  }
}
