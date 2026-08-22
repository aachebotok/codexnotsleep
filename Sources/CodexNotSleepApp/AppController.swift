import AppKit
import Foundation
import CodexNotSleepCore

@MainActor
final class AppController: NSObject {
  private static let legacyMigrationVersion = 2
  private static let legacyMigrationVersionKey = "legacyHookMigrationVersion"
  private static let backendRenewInterval: TimeInterval = 30
  static let lowBatterySleepThresholdPercent = 10.0
  static let menuIconName = "pointer.arrow.ipad.rays"

  private(set) var isProtectionEnabled: Bool
  private(set) var isPreparingProtection = false
  private(set) var isResolvingIssue = false
  private(set) var phase: ProtectionPhase = .idle
  private(set) var menuIssue: MenuIssue?

  private let defaults: UserDefaults
  private let protectionStore: ProtectionPreferenceStore
  private let legacyIntegrations: LegacyIntegrationMigrator
  private let backend: any SleepProtectionBackend
  private let backendWorker: SleepProtectionWorker
  private let batteryStatusProvider: any BatteryStatusProviding
  private let codexActivityProvider: any CodexActivityProviding
  private let activityWorker: CodexActivityWorker
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let lidBrightnessController: any LidBrightnessControlling
  private let protectionGraceSeconds: TimeInterval
  private let usesBackgroundSystemWork: Bool
  private let batteryQueue = DispatchQueue(
    label: "app.codexnotsleep.battery-status",
    qos: .utility
  )
  private let maintenanceQueue = DispatchQueue(
    label: "app.codexnotsleep.maintenance",
    qos: .utility
  )

  private var codexActivitySnapshot: CodexActivitySnapshot
  private var policy: SleepPolicyMachine
  private var lastBackendRenewAt = Date.distantPast
  private var backendHeld = false
  private var backendOperationInFlight = false
  private var evaluationPending = false
  private var evaluationRequestedAgain = false
  private var pendingActivationIssue: MenuIssue?
  private var started = false
  private var recoveryPending = false

  override convenience init() {
    self.init(startsAutomatically: true)
  }

  convenience init(startsAutomatically: Bool) {
    let defaults = UserDefaults.standard
    LegacyPreferencesMigrator(defaults: defaults).migrate()
    self.init(
      defaults: defaults,
      legacyIntegrations: LegacyIntegrationMigrator(),
      backend: CombinedSleepProtectionBackend(
        idleSleep: IdleSleepAssertionBackend(),
        closedLid: PMSetPowerProtectBackend()
      ),
      batteryStatusProvider: IOKitBatteryStatusProvider(),
      codexActivityProvider: CodexSessionActivityMonitor(),
      launchAtLoginController: LaunchAtLoginController(),
      startsAutomatically: startsAutomatically,
      lidBrightnessController: LidBrightnessController()
    )
  }

  init(
    defaults: UserDefaults,
    legacyIntegrations: LegacyIntegrationMigrator,
    backend: any SleepProtectionBackend,
    batteryStatusProvider: any BatteryStatusProviding = IOKitBatteryStatusProvider(),
    codexActivityProvider: any CodexActivityProviding = CodexSessionActivityMonitor(),
    launchAtLoginController: any LaunchAtLoginControlling = NoOpLaunchAtLoginController(),
    protectionGraceSeconds: TimeInterval = 15,
    startsAutomatically: Bool,
    lidBrightnessController: any LidBrightnessControlling = NoOpLidBrightnessController(),
    performsSystemWorkOffMainActor: Bool? = nil
  ) {
    let protectionStore = ProtectionPreferenceStore(defaults: defaults)
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
    backendWorker = SleepProtectionWorker(backend: backend)
    self.batteryStatusProvider = batteryStatusProvider
    self.codexActivityProvider = codexActivityProvider
    activityWorker = CodexActivityWorker(provider: codexActivityProvider)
    self.launchAtLoginController = launchAtLoginController
    self.lidBrightnessController = lidBrightnessController
    self.protectionGraceSeconds = protectionGraceSeconds
    usesBackgroundSystemWork = performsSystemWorkOffMainActor ?? startsAutomatically
    codexActivitySnapshot = codexActivityProvider.snapshot
    self.isProtectionEnabled = isProtectionEnabled
    backendHeld = backend.isHeld
    policy = SleepPolicyMachine(
      config: SleepPolicyConfig(autoMode: true, graceSeconds: protectionGraceSeconds)
    )

    super.init()

    if startsAutomatically {
      Task { @MainActor [weak self] in
        self?.start()
      }
    }
  }

  var visibleError: String? { menuIssue?.title }

  var statusTitle: String {
    if let menuIssue { return menuIssue.title }
    if isPreparingProtection { return "Setting up sleep protection" }
    if !isProtectionEnabled { return "Sleep protection is off" }

    switch phase {
    case .idle:
      return "Waiting"
    case .protected:
      return "Preventing sleep"
    case .grace:
      return "Finishing up"
    }
  }

  var menuIcon: String { Self.menuIconName }

  func start() {
    guard !started else { return }
    started = true

    if let launchAtLoginError = launchAtLoginController.enableByDefault() {
      NSLog("Codex Not Sleep launch-at-login setup failed: %@", launchAtLoginError)
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )

    if usesBackgroundSystemWork {
      startBackgroundRecovery()
      startLegacyMigrationOffMainActor()
    } else {
      do {
        try backend.recover()
        finishRecovery(.success(()))
      } catch {
        finishRecovery(.failure(error))
      }
      migrateLegacyIntegrations()
    }
  }

  func menuDidOpen() {
    if !started { start() }
  }

  /// Synchronous test seam. The live app receives snapshots from
  /// `CodexActivityWorker` instead of calling this from the main actor.
  func refreshCodexActivity() {
    guard !usesBackgroundSystemWork else {
      activityWorker.requestRefresh()
      return
    }
    codexActivitySnapshot = codexActivityProvider.refresh()
    requestEvaluation()
  }

  /// Compatibility seam for deterministic tests and manual recovery checks.
  /// There is no recurring timer calling this method.
  func tick() {
    if usesBackgroundSystemWork {
      activityWorker.requestRefresh()
    } else {
      refreshCodexActivity()
    }
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
      menuIssue = nil
      prepareBackend { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          recoverBackend { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
              protectionStore.clearPowerProtectSetupPending()
              isPreparingProtection = false
              applyProtectionPreference(true)
            case .failure(let error):
              finishSetup(.failure(error))
            }
          }
        case .failure(let error):
          finishSetup(.failure(error))
        }
      }
    } else {
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(true)
    }
  }

  func resolveMenuIssue() {
    guard let menuIssue, !isResolvingIssue else { return }
    switch menuIssue {
    case .permissionRequired:
      setProtectionEnabled(true)
    case .sleepRestoreRequired:
      restoreSleepFromMenu()
    }
  }

  /// Requests a clean quit. A background release must complete before the app
  /// terminates; otherwise a failed restore remains visible and recoverable.
  func quit() {
    guard started else {
      NSApplication.shared.terminate(nil)
      return
    }

    activityWorker.stop()
    activityWorker.reset()
    lidBrightnessController.reset()

    if usesBackgroundSystemWork {
      backendOperationInFlight = true
      backendWorker.release { [weak self] result in
        guard let self else { return }
        backendOperationInFlight = false
        switch result {
        case .success:
          backendHeld = false
          started = false
          removeTerminationObserver()
          NSApplication.shared.terminate(nil)
        case .failure(let error):
          recoveryPending = true
          menuIssue = .sleepRestoreRequired
          logHiddenError("restore sleep before quit", error: error)
        }
      }
    } else {
      do {
        try backend.release()
        started = false
        backendHeld = false
        removeTerminationObserver()
        NSApplication.shared.terminate(nil)
      } catch {
        menuIssue = .sleepRestoreRequired
        recoveryPending = true
        logHiddenError("restore sleep before quit", error: error)
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
        failures.append(integration == .codex ? "Codex" : "Claude")
      }
    }

    if failures.isEmpty {
      defaults.set(Self.legacyMigrationVersion, forKey: Self.legacyMigrationVersionKey)
    } else {
      NSLog(
        "Codex Not Sleep could not remove legacy integrations: %@",
        failures.joined(separator: ", ")
      )
    }
  }

  private func startBackgroundRecovery() {
    backendWorker.recover { [weak self] result in
      self?.finishRecovery(result)
    }
  }

  private func finishRecovery(_ result: Result<Void, Error>) {
    switch result {
    case .success:
      recoveryPending = false
      backendHeld = usesBackgroundSystemWork ? false : backend.isHeld
      menuIssue = nil
      if isProtectionEnabled { startActivityMonitoring() }
      requestEvaluation()
    case .failure(let error):
      recoveryPending = true
      phase = .idle
      menuIssue = .sleepRestoreRequired
      logHiddenError("recover sleep", error: error)
    }
  }

  private func startActivityMonitoring() {
    guard started, isProtectionEnabled else { return }
    activityWorker.start { [weak self] snapshot in
      guard let self else { return }
      guard started, isProtectionEnabled else { return }
      codexActivitySnapshot = snapshot
      requestEvaluation()
    }
  }

  private func stopActivityMonitoring() {
    activityWorker.stop()
    activityWorker.reset()
    if !usesBackgroundSystemWork {
      codexActivityProvider.reset()
    }
    codexActivitySnapshot = .idle
  }

  private func applyProtectionPreference(_ isEnabled: Bool) {
    self.isProtectionEnabled = isEnabled
    protectionStore.save(isEnabled)
    if isEnabled {
      menuIssue = nil
      startActivityMonitoring()
      requestEvaluation()
      if !usesBackgroundSystemWork {
        refreshCodexActivity()
      }
      return
    }

    stopActivityMonitoring()
    lidBrightnessController.setCodexWorking(false)
    if backendOperationInFlight {
      // A queued acquire/renew may finish after the user disables the toggle.
      // Re-evaluate after that operation so it cannot leave protection held.
      evaluationRequestedAgain = true
    }
    policy = SleepPolicyMachine(
      config: SleepPolicyConfig(autoMode: true, graceSeconds: protectionGraceSeconds)
    )
    phase = .idle
    if isBackendHeld || backendOperationInFlight || recoveryPending {
      requestRelease()
    }
  }

  private func requestEvaluation() {
    guard !recoveryPending else { return }
    guard usesBackgroundSystemWork else {
      evaluateProtection(batteryStatus: batteryStatusProvider.currentStatus())
      return
    }
    guard !evaluationPending else {
      evaluationRequestedAgain = true
      return
    }

    evaluationPending = true
    let provider = batteryStatusProvider
    batteryQueue.async { [weak self] in
      let status = provider.currentStatus()
      DispatchQueue.main.async {
        guard let self else { return }
        self.evaluationPending = false
        self.evaluateProtection(batteryStatus: status)
        if self.evaluationRequestedAgain {
          self.evaluationRequestedAgain = false
          self.requestEvaluation()
        }
      }
    }
  }

  private func evaluateProtection(batteryStatus: BatteryStatus?) {
    guard !recoveryPending else { return }

    let lowBattery = batteryStatus?.isAtOrBelow(Self.lowBatterySleepThresholdPercent) ?? false
    if !isProtectionEnabled || lowBattery {
      lidBrightnessController.setCodexWorking(false)
      policy = SleepPolicyMachine(
        config: SleepPolicyConfig(autoMode: true, graceSeconds: protectionGraceSeconds)
      )
      phase = .idle
      if isBackendHeld { requestRelease() }
      return
    }

    let activeCount = codexActivitySnapshot.effectiveActiveCount
    let isCodexWorking: Bool
    if case .active = codexActivitySnapshot {
      isCodexWorking = true
    } else {
      isCodexWorking = false
    }
    lidBrightnessController.setCodexWorking(isCodexWorking)
    phase = policy.evaluate(activeCount: activeCount)

    guard !backendOperationInFlight else {
      evaluationRequestedAgain = true
      return
    }
    if policy.shouldProtect {
      let now = Date.now
      if isBackendHeld {
        guard now.timeIntervalSince(lastBackendRenewAt) >= Self.backendRenewInterval else {
          return
        }
        requestRenew()
      } else {
        requestAcquire()
      }
    } else if isBackendHeld {
      requestRelease()
    }
  }

  private var isBackendHeld: Bool {
    usesBackgroundSystemWork ? backendHeld : backend.isHeld
  }

  private func prepareBackend(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    if usesBackgroundSystemWork {
      backendWorker.prepare(completion: completion)
    } else {
      do {
        try backend.prepare()
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func recoverBackend(
    completion: @escaping @MainActor @Sendable (Result<Void, Error>) -> Void
  ) {
    if usesBackgroundSystemWork {
      backendWorker.recover(completion: completion)
    } else {
      do {
        try backend.recover()
        completion(.success(()))
      } catch {
        completion(.failure(error))
      }
    }
  }

  private func finishSetup(_ result: Result<Void, Error>) {
    isPreparingProtection = false
    switch result {
    case .success:
      protectionStore.clearPowerProtectSetupPending()
      applyProtectionPreference(true)
    case .failure(let error):
      let wasCancelled = (error as? PowerProtectError) == .setupCancelled
      if wasCancelled { protectionStore.clearPowerProtectSetupPending() }
      applyProtectionPreference(false)
      menuIssue = wasCancelled ? nil : .permissionRequired
      if !wasCancelled { logHiddenError("configure closed-lid protection", error: error) }
    }
  }

  private enum BackendOperation {
    case acquire
    case renew
    case release
  }

  private func requestAcquire() {
    backendOperationInFlight = true
    if usesBackgroundSystemWork {
      backendWorker.acquire { [weak self] result in
        self?.finishBackendOperation(.acquire, result: result)
      }
    } else {
      do {
        try backend.acquire()
        finishBackendOperation(.acquire, result: .success(()))
      } catch {
        finishBackendOperation(.acquire, result: .failure(error))
      }
    }
  }

  private func requestRenew() {
    backendOperationInFlight = true
    if usesBackgroundSystemWork {
      backendWorker.renew { [weak self] result in
        self?.finishBackendOperation(.renew, result: result)
      }
    } else {
      do {
        try backend.renew()
        finishBackendOperation(.renew, result: .success(()))
      } catch {
        finishBackendOperation(.renew, result: .failure(error))
      }
    }
  }

  private func requestRelease() {
    guard !backendOperationInFlight else { return }
    backendOperationInFlight = true
    if usesBackgroundSystemWork {
      backendWorker.release { [weak self] result in
        self?.finishBackendOperation(.release, result: result)
      }
    } else {
      do {
        try backend.release()
        finishBackendOperation(.release, result: .success(()))
      } catch {
        finishBackendOperation(.release, result: .failure(error))
      }
    }
  }

  private func finishBackendOperation(
    _ operation: BackendOperation,
    result: Result<Void, Error>
  ) {
    backendOperationInFlight = false
    switch result {
    case .success:
      if operation == .release {
        backendHeld = false
        recoveryPending = false
        lastBackendRenewAt = .distantPast
        let activationIssue = isProtectionEnabled ? pendingActivationIssue : nil
        pendingActivationIssue = nil
        menuIssue = activationIssue
      } else {
        backendHeld = true
        lastBackendRenewAt = Date.now
        menuIssue = nil
      }
    case .failure(let error):
      if operation == .release {
        menuIssue = .sleepRestoreRequired
        logHiddenError("restore sleep", error: error)
      } else {
        let activationIssue: MenuIssue? = (error as? PowerProtectError) == .setupRequired
          ? .permissionRequired
          : nil
        menuIssue = activationIssue
        if activationIssue == nil { logHiddenError("activate protection", error: error) }
        requestReleaseAfterActivationFailure(preserving: activationIssue)
      }
    }

    if operation != .release, !isProtectionEnabled || !policy.shouldProtect {
      requestRelease()
      return
    }
    if evaluationRequestedAgain {
      evaluationRequestedAgain = false
      requestEvaluation()
    }
  }

  private func requestReleaseAfterActivationFailure(preserving issue: MenuIssue?) {
    guard !backendOperationInFlight else { return }
    pendingActivationIssue = issue
    requestRelease()
  }

  private func restoreSleepFromMenu() {
    isResolvingIssue = true
    let release: () -> Void = { [weak self] in
      guard let self else { return }
      if usesBackgroundSystemWork {
        backendWorker.release { [weak self] result in
          self?.finishMenuRecovery(result)
        }
      } else {
        do {
          try backend.release()
          finishMenuRecovery(.success(()))
        } catch {
          finishMenuRecovery(.failure(error))
        }
      }
    }

    // This is an explicit recovery action. Run setup verification off the
    // main actor before attempting a release, because an old lease may remain
    // after the sudoers rule was removed.
    prepareBackend { [weak self] result in
      guard let self else { return }
      switch result {
      case .success: release()
      case .failure(let error): finishMenuRecovery(.failure(error))
      }
    }
  }

  private func finishMenuRecovery(_ result: Result<Void, Error>) {
    isResolvingIssue = false
    switch result {
    case .success:
      recoveryPending = false
      backendHeld = false
      lastBackendRenewAt = .distantPast
      pendingActivationIssue = nil
      menuIssue = nil
      if isProtectionEnabled {
        startActivityMonitoring()
        requestEvaluation()
      }
    case .failure(let error):
      pendingActivationIssue = nil
      menuIssue = .sleepRestoreRequired
      logHiddenError("restore sleep from menu", error: error)
    }
  }

  private func startLegacyMigrationOffMainActor() {
    guard defaults.integer(forKey: Self.legacyMigrationVersionKey) < Self.legacyMigrationVersion else {
      return
    }
    let migrator = legacyIntegrations
    maintenanceQueue.async {
      var failures: [String] = []
      for integration in IntegrationKind.allCases where migrator.isInstalled(integration) {
        do {
          try migrator.remove(integration)
        } catch {
          failures.append(integration == .codex ? "Codex" : "Claude")
        }
      }
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        if failures.isEmpty {
          self.defaults.set(
            Self.legacyMigrationVersion,
            forKey: Self.legacyMigrationVersionKey
          )
        } else {
          NSLog(
            "Codex Not Sleep could not remove legacy integrations: %@",
            failures.joined(separator: ", ")
          )
        }
      }
    }
  }

  private func logHiddenError(_ operation: String, error: Error) {
    NSLog("Codex Not Sleep failed to %@: %@", operation, error.localizedDescription)
  }

  @objc
  private func applicationWillTerminate() {
    shutdown()
  }

  private func shutdown() {
    guard started else { return }
    started = false
    activityWorker.stop()
    activityWorker.reset()
    lidBrightnessController.reset()
    removeTerminationObserver()
    if usesBackgroundSystemWork {
      backendWorker.release { _ in }
    } else {
      try? backend.release()
    }
  }

  private func removeTerminationObserver() {
    NotificationCenter.default.removeObserver(self)
  }
}
