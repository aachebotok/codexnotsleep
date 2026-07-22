import Foundation
import Testing

@testable import MethamphetamineApp

@Suite
@MainActor
struct AgentProtectionStoreTests {
  @Test
  func missingPreferenceStartsDisabledAndPersistsExplicitChoice() throws {
    let suiteName = "Methamphetamine.AgentProtectionStoreTests.\(UUID().uuidString)"
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
    let suiteName = "Methamphetamine.AgentProtectionStoreTests.\(UUID().uuidString)"
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
    let suiteName = "Methamphetamine.AgentProtectionStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(["codex"], forKey: "enabledCodingAgentIDs")
    defaults.set(false, forKey: "agentSleepProtectionEnabled")

    let store = AgentProtectionStore(defaults: defaults)

    #expect(!store.load())
  }

  @Test
  func lowBatterySleepDefaultsOnAndPersistsExplicitChoice() throws {
    let suiteName = "Methamphetamine.AgentProtectionStoreTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = AgentProtectionStore(defaults: defaults)
    #expect(store.loadLowBatterySleep())

    store.saveLowBatterySleep(false)

    let restoredStore = AgentProtectionStore(defaults: defaults)
    #expect(!restoredStore.loadLowBatterySleep())
  }
}
