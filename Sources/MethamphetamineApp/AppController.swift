import AppKit
import Combine
import Foundation
import MethamphetamineCore

@MainActor
final class AppController: NSObject, ObservableObject {
  private static let legacyMigrationVersion = 2
  private static let legacyMigrationVersionKey = "legacyHookMigrationVersion"
  static let lowBatterySleepThresholdPercent = 10.0

  @Published private(set) var isProtectionEnabled: Bool
  @Published private(set) var isLowBatterySleepEnabled: Bool
  @Published private(set) var isPreparingProtection = false
  @Published private(set) var phase: ProtectionPhase = .idle
  @Published private var protectionError: String?
  @Published private var setupError: String?
  @Published private var configurationError: String?

  var detectedAgents: [DetectedCodingAgent] = [] {
    didSet { evaluateProtection() }
  }

  private let detector: CodingAgentSystemScanner
  private let defaults: UserDefaults
  private let protectionStore: AgentProtectionStore
  private let legacyIntegrations: LegacyIntegrationMigrator
  private let backend: SleepProtectionBackend
  private let batteryStatusProvider: BatteryStatusProviding
  private var policy: SleepPolicyMachine
  private var timer: Timer?
  private var lastScanAt = Date.distantPast
  private var started = false
  private var recoveryPending = false

  override convenience init() {
    self.init(startsAutomatically: true)
  }

  convenience init(startsAutomatically: Bool) {
    self.init(
      defaults: .standard,
      detector: CodingAgentSystemScanner(),
      legacyIntegrations: LegacyIntegrationMigrator(),
      backend: CombinedSleepProtectionBackend(
        idleSleep: IdleSleepAssertionBackend(),
        closedLid: PMSetPowerProtectBackend()
      ),
      batteryStatusProvider: IOKitBatteryStatusProvider(),
      startsAutomatically: startsAutomatically
    )
  }

  init(
    defaults: UserDefaults,
    detector: CodingAgentSystemScanner,
    legacyIntegrations: LegacyIntegrationMigrator,
    backend: SleepProtectionBackend,
    batteryStatusProvider: BatteryStatusProviding = IOKitBatteryStatusProvider(),
    startsAutomatically: Bool
  ) {
    let protectionStore = AgentProtectionStore(defaults: defaults)
    let storedPreference = protectionStore.load()
    let isLowBatterySleepEnabled = protectionStore.loadLowBatterySleep()
    protectionStore.saveLowBatterySleep(isLowBatterySleepEnabled)
    let pendingSetup = protectionStore.isPowerProtectSetupPending
    let isProtectionEnabled: Bool
    if backend.requiresSetup && (storedPreference || pendingSetup) {
      protectionStore.markPowerProtectSetupPending()
      isProtectionEnabled = false
    } else if !backend.requiresSetup && pendingSetup {
      protectionStore.clearPowerProtectSetupPending()
      isProtectionEnabled = true
    } else {
      isProtectionEnabled = storedPreference
    }
    if !protectionStore.hasStoredPreference || storedPreference != isProtectionEnabled {
      protectionStore.save(isProtectionEnabled)
    }

    self.detector = detector
    self.defaults = defaults
    self.protectionStore = protectionStore
    self.legacyIntegrations = legacyIntegrations
    self.backend = backend
    self.batteryStatusProvider = batteryStatusProvider
    self.isProtectionEnabled = isProtectionEnabled
    self.isLowBatterySleepEnabled = isLowBatterySleepEnabled
    policy = SleepPolicyMachine(
      config: SleepPolicyConfig(
        autoMode: true,
        graceSeconds: 0
      )
    )

    super.init()

    if startsAutomatically {
      Task { @MainActor [weak self] in
        self?.start()
      }
    }
  }

  var visibleError: String? {
    protectionError ?? setupError ?? configurationError
  }

  var statusTitle: String {
    if protectionError != nil { return "Ошибка защиты" }
    if isPreparingProtection { return "Настройка защиты" }
    if setupError != nil { return "Не удалось настроить защиту" }
    if configurationError != nil { return "Не удалось обновить старую версию" }
    if !isProtectionEnabled { return "Защита от сна выключена" }

    switch phase {
    case .idle:
      return "Ожидание"
    case .protected:
      return "Mac защищён от сна"
    case .grace:
      return "Период завершения"
    }
  }

  var menuIcon: String {
    if visibleError != nil { return "exclamationmark.circle.fill" }
    return "pill.fill"
  }

  func start() {
    guard !started else { return }
    started = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )

    let workspaceNotifications = NSWorkspace.shared.notificationCenter
    workspaceNotifications.addObserver(
      self,
      selector: #selector(systemInventoryDidChange),
      name: NSWorkspace.didLaunchApplicationNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(systemInventoryDidChange),
      name: NSWorkspace.didTerminateApplicationNotification,
      object: nil
    )
    workspaceNotifications.addObserver(
      self,
      selector: #selector(systemInventoryDidChange),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    do {
      try backend.recover()
      recoveryPending = false
      protectionError = nil
    } catch {
      recoveryPending = true
      protectionError = error.localizedDescription
    }

    migrateLegacyIntegrations()
    refreshAgents(refreshInstallations: true)

    timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
  }

  func menuDidOpen() {
    if started {
      refreshAgents(refreshInstallations: true)
    } else {
      start()
    }
  }

  private func tick() {
    if Date.now.timeIntervalSince(lastScanAt) >= 2 {
      refreshAgents()
    } else {
      evaluateProtection()
    }
  }

  private func refreshAgents(refreshInstallations: Bool = false) {
    detectedAgents = detector.detectAgents(refreshInstallations: refreshInstallations)
    lastScanAt = .now
  }

  func setProtectionEnabled(_ isEnabled: Bool) {
    if !isEnabled {
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(false)
      return
    }
    guard !isProtectionEnabled, !isPreparingProtection else { return }

    if backend.requiresSetup {
      isPreparingProtection = true
      setupError = nil
      Task { @MainActor [weak self] in
        guard let self else { return }
        do {
          try await backend.prepare()
          guard !backend.requiresSetup else {
            throw PowerProtectError.setupVerificationFailed
          }
          try backend.recover()
          recoveryPending = false
          protectionStore.clearPowerProtectSetupPending()
          isPreparingProtection = false
          applyProtectionPreference(true)
        } catch {
          isPreparingProtection = false
          if let powerProtectError = error as? PowerProtectError,
            powerProtectError == .setupCancelled
          {
            protectionStore.clearPowerProtectSetupPending()
          }
          setupError = error.localizedDescription
          applyProtectionPreference(false, clearSetupError: false)
        }
      }
    } else {
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(true)
    }
  }

  func setLowBatterySleepEnabled(_ isEnabled: Bool) {
    isLowBatterySleepEnabled = isEnabled
    protectionStore.saveLowBatterySleep(isEnabled)
    evaluateProtection()
  }

  private func applyProtectionPreference(
    _ isEnabled: Bool,
    clearSetupError: Bool = true
  ) {
    isProtectionEnabled = isEnabled
    protectionStore.save(isEnabled)
    if clearSetupError { setupError = nil }

    if isEnabled {
      evaluateProtection()
    } else {
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(autoMode: true, graceSeconds: 0)
      )
      do {
        try backend.release()
        protectionError = nil
      } catch {
        protectionError = error.localizedDescription
      }
      phase = .idle
    }
  }

  private func evaluateProtection() {
    if recoveryPending {
      do {
        try backend.recover()
        recoveryPending = false
        protectionError = nil
      } catch {
        phase = .idle
        protectionError = error.localizedDescription
        return
      }
    }

    let shouldAllowSleepForLowBattery =
      isLowBatterySleepEnabled
      && (batteryStatusProvider.currentStatus()?.isBelow(
        Self.lowBatterySleepThresholdPercent
      ) ?? false)
    let activeCount =
      isProtectionEnabled && !shouldAllowSleepForLowBattery
      ? detectedAgents.count(where: \.isRunning)
      : 0
    let wasHeld = backend.isHeld
    phase = policy.evaluate(activeCount: activeCount)

    if policy.shouldProtect {
      do {
        if wasHeld {
          try backend.renew()
        } else {
          try backend.acquire()
        }
        protectionError = nil
      } catch {
        let activationError = error
        do {
          try backend.release()
          protectionError = activationError.localizedDescription
        } catch {
          protectionError = error.localizedDescription
        }
      }
    } else {
      if wasHeld {
        do {
          try backend.release()
          protectionError = nil
        } catch {
          protectionError = error.localizedDescription
        }
      }
    }
  }

  func migrateLegacyIntegrations() {
    guard
      defaults.integer(forKey: Self.legacyMigrationVersionKey)
        < Self.legacyMigrationVersion
    else { return }

    var failures: [String] = []

    for integration in IntegrationKind.allCases where legacyIntegrations.isInstalled(integration) {
      do {
        try legacyIntegrations.remove(integration)
      } catch {
        let name = integration == .codex ? "Codex" : "Claude"
        failures.append(name)
      }
    }

    configurationError =
      failures.isEmpty
      ? nil
      : "Не удалось убрать старую интеграцию: \(failures.joined(separator: ", "))"

    if failures.isEmpty {
      defaults.set(Self.legacyMigrationVersion, forKey: Self.legacyMigrationVersionKey)
    }
  }

  @objc
  private func systemInventoryDidChange() {
    refreshAgents(refreshInstallations: true)
  }

  @objc
  private func applicationWillTerminate() {
    shutdown()
  }

  private func shutdown() {
    guard started else { return }
    started = false
    timer?.invalidate()
    timer = nil
    do {
      try backend.release()
    } catch {
      NSLog("Methamphetamine failed to restore sleep: %@", error.localizedDescription)
    }
    NotificationCenter.default.removeObserver(self)
    NSWorkspace.shared.notificationCenter.removeObserver(self)
  }
}
