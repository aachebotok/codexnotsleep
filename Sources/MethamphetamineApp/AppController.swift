import AppKit
import Combine
import Foundation
import MethamphetamineCore

@MainActor
final class AppController: NSObject, ObservableObject {
  private static let legacyMigrationVersion = 2
  private static let legacyMigrationVersionKey = "legacyHookMigrationVersion"
  private static let activityRefreshInterval: TimeInterval = 1
  private static let backendRenewInterval: TimeInterval = 30
  static let lowBatterySleepThresholdPercent = 10.0

  @Published private(set) var isProtectionEnabled: Bool
  @Published private(set) var isPreparingProtection = false
  @Published private(set) var phase: ProtectionPhase = .idle
  @Published private var protectionError: String?
  @Published private var setupError: String?
  @Published private var configurationError: String?
  @Published private var launchAtLoginError: String?
  @Published private var activityWarning: String?

  var detectedAgents: [DetectedCodingAgent] = [] {
    didSet { evaluateProtection() }
  }

  private let defaults: UserDefaults
  private let protectionStore: AgentProtectionStore
  private let legacyIntegrations: LegacyIntegrationMigrator
  private let backend: SleepProtectionBackend
  private let batteryStatusProvider: BatteryStatusProviding
  private let codexActivityProvider: CodexActivityProviding
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let protectionGraceSeconds: TimeInterval
  private var codexActivitySnapshot: CodexActivitySnapshot
  private var policy: SleepPolicyMachine
  private var timer: Timer?
  private var lastBackendRenewAt = Date.distantPast
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
      codexActivityProvider: CodexSessionActivityMonitor(),
      launchAtLoginController: LaunchAtLoginController(),
      startsAutomatically: startsAutomatically
    )
  }

  init(
    defaults: UserDefaults,
    detector _: CodingAgentSystemScanner,
    legacyIntegrations: LegacyIntegrationMigrator,
    backend: SleepProtectionBackend,
    batteryStatusProvider: BatteryStatusProviding = IOKitBatteryStatusProvider(),
    codexActivityProvider: CodexActivityProviding = CodexSessionActivityMonitor(),
    launchAtLoginController: any LaunchAtLoginControlling = NoOpLaunchAtLoginController(),
    protectionGraceSeconds: TimeInterval = 3,
    startsAutomatically: Bool
  ) {
    let protectionStore = AgentProtectionStore(defaults: defaults)
    let storedPreference = protectionStore.load()
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

    self.defaults = defaults
    self.protectionStore = protectionStore
    self.legacyIntegrations = legacyIntegrations
    self.backend = backend
    self.batteryStatusProvider = batteryStatusProvider
    self.codexActivityProvider = codexActivityProvider
    self.launchAtLoginController = launchAtLoginController
    self.protectionGraceSeconds = protectionGraceSeconds
    codexActivitySnapshot = codexActivityProvider.snapshot
    self.isProtectionEnabled = isProtectionEnabled
    policy = SleepPolicyMachine(
      config: SleepPolicyConfig(
        autoMode: true,
        graceSeconds: protectionGraceSeconds
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
    protectionError ?? setupError ?? configurationError ?? launchAtLoginError ?? activityWarning
  }

  var statusTitle: String {
    if protectionError != nil { return "Ошибка защиты" }
    if isPreparingProtection { return "Настройка защиты" }
    if setupError != nil { return "Не удалось настроить защиту" }
    if configurationError != nil { return "Не удалось обновить старую версию" }
    if launchAtLoginError != nil { return "Не удалось включить автозапуск" }
    if activityWarning != nil {
      return codexActivitySnapshot.effectiveActiveCount > 0 && backend.isHeld
        ? "Codex защищён в резервном режиме"
        : "Не удалось определить активность Codex"
    }
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

    do {
      try backend.recover()
      recoveryPending = false
      protectionError = nil
    } catch {
      recoveryPending = true
      protectionError = error.localizedDescription
    }

    migrateLegacyIntegrations()
    launchAtLoginError = launchAtLoginController.enableByDefault()
    if isProtectionEnabled {
      refreshCodexActivity()
    }

    timer = Timer.scheduledTimer(
      withTimeInterval: Self.activityRefreshInterval,
      repeats: true
    ) { [weak self] _ in
      Task { @MainActor in
        self?.tick()
      }
    }
  }

  func menuDidOpen() {
    if started, isProtectionEnabled {
      refreshCodexActivity()
    } else if !started {
      start()
    }
  }

  func tick() {
    guard isProtectionEnabled else {
      if backend.isHeld || recoveryPending {
        evaluateProtection()
      }
      return
    }
    refreshCodexActivity()
  }

  func refreshCodexActivity() {
    codexActivitySnapshot = codexActivityProvider.refresh()
    updateActivityWarning()
    evaluateProtection()
  }

  private func updateActivityWarning() {
    guard isProtectionEnabled, codexActivitySnapshot.usesFallback else {
      activityWarning = nil
      return
    }
    activityWarning = "Не удалось точно определить задачу Codex."
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

  private func applyProtectionPreference(
    _ isEnabled: Bool,
    clearSetupError: Bool = true
  ) {
    isProtectionEnabled = isEnabled
    protectionStore.save(isEnabled)
    if clearSetupError { setupError = nil }
    updateActivityWarning()

    if isEnabled {
      refreshCodexActivity()
    } else {
      codexActivityProvider.reset()
      codexActivitySnapshot = .idle
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(
          autoMode: true,
          graceSeconds: protectionGraceSeconds
        )
      )
      do {
        try backend.release()
        lastBackendRenewAt = .distantPast
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
      batteryStatusProvider.currentStatus()?.isAtOrBelow(
        Self.lowBatterySleepThresholdPercent
      ) ?? false
    if !isProtectionEnabled || shouldAllowSleepForLowBattery {
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(
          autoMode: true,
          graceSeconds: protectionGraceSeconds
        )
      )
      if backend.isHeld {
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
          protectionError = nil
        } catch {
          protectionError = error.localizedDescription
        }
      }
      phase = .idle
      return
    }

    let activeCount = codexActivitySnapshot.effectiveActiveCount
    let wasHeld = backend.isHeld
    let now = Date.now
    phase = policy.evaluate(activeCount: activeCount)

    if policy.shouldProtect {
      do {
        if wasHeld {
          if now.timeIntervalSince(lastBackendRenewAt) >= Self.backendRenewInterval {
            try backend.renew()
            lastBackendRenewAt = now
          }
        } else {
          try backend.acquire()
          lastBackendRenewAt = now
        }
        protectionError = nil
      } catch {
        let activationError = error
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
          protectionError = activationError.localizedDescription
        } catch {
          protectionError = error.localizedDescription
        }
      }
    } else {
      if wasHeld {
        do {
          try backend.release()
          lastBackendRenewAt = .distantPast
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
  }
}
