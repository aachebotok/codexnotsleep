import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct AgentProtectionStoreTests {
  @Test
  func missingPreferenceStartsDisabledAndPersistsExplicitChoice() throws {
    let suiteName = "CodexNotSleep.AgentProtectionStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AgentProtectionStore(defaults: defaults)
    #expect(!store.hasStoredPreference)
    #expect(!store.load())

    store.save(true)

    let restoredStore = AgentProtectionStore(defaults: defaults)
    #expect(restoredStore.hasStoredPreference)
    #expect(restoredStore.load())
  }

  @Test
  func legacyAgentSelectionMapsToGlobalPreference() throws {
    let suiteName = "CodexNotSleep.AgentProtectionStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = AgentProtectionStore(defaults: defaults)

    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")
    #expect(store.load())

    defaults.set([], forKey: "enabledCodingAgentIDs")
    #expect(!store.load())
  }

  @Test
  func globalPreferenceOverridesLegacySelection() throws {
    let suiteName = "CodexNotSleep.AgentProtectionStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let store = AgentProtectionStore(defaults: defaults)

    #expect(!store.load())
  }

  @Test
  func migratesPreferencesFromPreviousBundleIdentifierOnce() throws {
    let currentSuiteName = "CodexNotSleep.AgentProtectionStoreTests.current.\(UUID().uuidString)"
    let legacySuiteName = "CodexNotSleep.AgentProtectionStoreTests.legacy.\(UUID().uuidString)"
    let currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
    let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    legacyDefaults.set(true, forKey: AgentProtectionStore.key)
    legacyDefaults.set(true, forKey: AgentProtectionStore.pendingPowerProtectKey)
    legacyDefaults.set(["codex"], forKey: AgentProtectionStore.legacySelectionKey)

    let migrator = LegacyPreferencesMigrator(
      defaults: currentDefaults,
      legacyDefaults: legacyDefaults
    )
    migrator.migrate()

    #expect(currentDefaults.bool(forKey: AgentProtectionStore.key))
    #expect(currentDefaults.bool(forKey: AgentProtectionStore.pendingPowerProtectKey))
    #expect(currentDefaults.stringArray(forKey: AgentProtectionStore.legacySelectionKey) == ["codex"])

    legacyDefaults.set(false, forKey: AgentProtectionStore.key)
    migrator.migrate()
    #expect(currentDefaults.bool(forKey: AgentProtectionStore.key))
  }

  @Test
  func migrationDoesNotOverwriteCurrentPreferences() throws {
    let currentSuiteName = "CodexNotSleep.AgentProtectionStoreTests.current.\(UUID().uuidString)"
    let legacySuiteName = "CodexNotSleep.AgentProtectionStoreTests.legacy.\(UUID().uuidString)"
    let currentDefaults = try #require(UserDefaults(suiteName: currentSuiteName))
    let legacyDefaults = try #require(UserDefaults(suiteName: legacySuiteName))
    defer {
      currentDefaults.removePersistentDomain(forName: currentSuiteName)
      legacyDefaults.removePersistentDomain(forName: legacySuiteName)
    }

    currentDefaults.set(false, forKey: AgentProtectionStore.key)
    legacyDefaults.set(true, forKey: AgentProtectionStore.key)

    LegacyPreferencesMigrator(
      defaults: currentDefaults,
      legacyDefaults: legacyDefaults
    ).migrate()

    #expect(currentDefaults.object(forKey: AgentProtectionStore.key) != nil)
    #expect(!currentDefaults.bool(forKey: AgentProtectionStore.key))
  }
}
