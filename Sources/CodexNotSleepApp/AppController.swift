import AppKit
import CodexNotSleepCore
import Foundation

@MainActor
final class AppController: NSObject {
  private static let backendRenewInterval: TimeInterval = 30
  static let lowBatterySleepThresholdPercent = 10.0
  static let menuIconName = "pointer.arrow.ipad.rays"

  private(set) var isProtectionEnabled: Bool
  private(set) var isPreparingProtection = false
  private(set) var isPreparingClosedLid = false
  private(set) var isResolvingIssue = false
  private(set) var isClosedLidEnabled: Bool
  private(set) var phase: ProtectionPhase = .idle
  private(set) var menuIssue: MenuIssue?

  private let protectionStore: ProtectionPreferenceStore
  private let backend: any SleepProtectionBackend
  private let closedLidProtection: (any ClosedLidProtectionManaging)?
  private let backendWorker: SleepProtectionWorker
  private let batteryStatusProvider: any BatteryStatusProviding
  private let codexActivityProvider: any CodexActivityProviding
  private let activityWorker: CodexActivityWorker
  private let launchAtLoginController: any LaunchAtLoginControlling
  private let lidBrightnessController: any LidBrightnessControlling
  private let graceDeadlineScheduler: any GraceDeadlineScheduling
  private let protectionGraceSeconds: TimeInterval
  private let now: () -> Date
  private let usesBackgroundSystemWork: Bool
  private let batteryQueue = DispatchQueue(
    label: "app.codexnotsleep.battery-status",
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
  private var closedLidPreferenceNeedsMigration = false
  private var quitInProgress = false
  private var pendingClosedLidReleaseAfterRepair = false

  override convenience init() {
    self.init(startsAutomatically: true)
  }

  convenience init(startsAutomatically: Bool) {
    let defaults = UserDefaults.standard
    LegacyPreferencesMigrator(defaults: defaults).migrate()
    let protectionStore = ProtectionPreferenceStore(defaults: defaults)
    let closedLidEnabled = protectionStore.loadClosedLidPreference() ?? false
    self.init(
      defaults: defaults,
      backend: CombinedSleepProtectionBackend(
        idleSleep: IdleSleepAssertionBackend(),
        closedLid: PMSetPowerProtectBackend(closedLidEnabled: closedLidEnabled),
        closedLidEnabled: closedLidEnabled
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
    backend: any SleepProtectionBackend,
    batteryStatusProvider: any BatteryStatusProviding = IOKitBatteryStatusProvider(),
    codexActivityProvider: any CodexActivityProviding = CodexSessionActivityMonitor(),
    launchAtLoginController: any LaunchAtLoginControlling = NoOpLaunchAtLoginController(),
    protectionGraceSeconds: TimeInterval = 15,
    startsAutomatically: Bool,
    lidBrightnessController: any LidBrightnessControlling = NoOpLidBrightnessController(),
    performsSystemWorkOffMainActor: Bool? = nil,
    graceDeadlineScheduler: any GraceDeadlineScheduling = RunLoopGraceDeadlineScheduler(),
    now: @escaping () -> Date = Date.init
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

    self.protectionStore = protectionStore
    self.backend = backend
    closedLidProtection = backend as? any ClosedLidProtectionManaging
    closedLidPreferenceNeedsMigration =
      closedLidProtection != nil
      && protectionStore.loadClosedLidPreference() == nil
    backendWorker = SleepProtectionWorker(backend: backend)
    self.batteryStatusProvider = batteryStatusProvider
    self.codexActivityProvider = codexActivityProvider
    activityWorker = CodexActivityWorker(provider: codexActivityProvider)
    self.launchAtLoginController = launchAtLoginController
    self.lidBrightnessController = lidBrightnessController
    self.graceDeadlineScheduler = graceDeadlineScheduler
    self.protectionGraceSeconds = protectionGraceSeconds
    self.now = now
    usesBackgroundSystemWork = performsSystemWorkOffMainActor ?? startsAutomatically
    codexActivitySnapshot = codexActivityProvider.snapshot
    self.isProtectionEnabled = isProtectionEnabled
    isClosedLidEnabled = (backend as? any ClosedLidProtectionManaging)?.isClosedLidEnabled ?? false
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

  var closedLidMenuTitle: String? {
    guard closedLidProtection != nil else { return nil }
    return "Keep Awake with Lid Closed"
  }

  func start() {
    guard !started else { return }
    started = true

    if let launchAtLoginError = launchAtLoginController.enableByDefault() {
      NSLog("Codexetine launch-at-login setup failed: %@", launchAtLoginError)
    }

    batteryStatusProvider.startMonitoring { [weak self] in
      Task { @MainActor in
        self?.requestEvaluation()
      }
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(applicationWillTerminate),
      name: NSApplication.willTerminateNotification,
      object: nil
    )

    if usesBackgroundSystemWork {
      startBackgroundRecovery()
    } else {
      do {
        try backend.recover()
        finishRecovery(.success(()))
      } catch {
        finishRecovery(.failure(error))
      }
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
      enableClosedLidProtection()
    case .sleepRestoreRequired:
      restoreSleepFromMenu()
    case .closedLidSetupRepairRequired:
      repairClosedLidSupport()
    case .closedLidRecoveryRequired:
      restoreClosedLidFromMenu()
    }
  }

  func toggleClosedLidProtection() {
    guard closedLidProtection != nil, !isPreparingClosedLid else { return }
    if isClosedLidEnabled {
      setClosedLidMode(false)
    } else {
      enableClosedLidProtection()
    }
  }

  /// Requests a clean quit. A background release must complete before the app
  /// terminates; otherwise a failed restore remains visible and recoverable.
  func quit() {
    graceDeadlineScheduler.cancel()
    guard !quitInProgress else { return }
    guard started else {
      NSApplication.shared.terminate(nil)
      return
    }

    quitInProgress = true
    batteryStatusProvider.stopMonitoring()
    activityWorker.stop()
    activityWorker.reset()
    lidBrightnessController.restoreForShutdown { [weak self] result in
      guard let self else { return }
      if result == .exhausted {
        NSLog("Codexetine bounded brightness restoration exhausted before quit")
      }
      releaseForQuit()
    }
  }

  private func releaseForQuit() {
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
          handleFailedQuit(error)
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
        handleFailedQuit(error)
        logHiddenError("restore sleep before quit", error: error)
      }
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
      if closedLidPreferenceNeedsMigration {
        migrateClosedLidPreference()
      } else {
        if isProtectionEnabled { startActivityMonitoring() }
        requestEvaluation()
      }
    case .failure(let error):
      if error is ClosedLidProtectionError {
        recoveryPending = false
        backendHeld = backend.isHeld
        if isClosedLidSetupRequired(error) {
          pendingClosedLidReleaseAfterRepair = true
        }
        menuIssue = menuIssue(for: error)
        if isProtectionEnabled { startActivityMonitoring() }
        requestEvaluation()
        logHiddenError("recover optional closed-lid protection", error: error)
        return
      }
      graceDeadlineScheduler.cancel()
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
    graceDeadlineScheduler.cancel()
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
      graceDeadlineScheduler.cancel()
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
    phase = policy.evaluate(activeCount: activeCount, now: now())
    synchronizeGraceDeadline()

    guard !backendOperationInFlight else {
      evaluationRequestedAgain = true
      return
    }
    if policy.shouldProtect {
      let currentTime = now()
      if isBackendHeld {
        guard currentTime.timeIntervalSince(lastBackendRenewAt) >= Self.backendRenewInterval else {
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

  private func synchronizeGraceDeadline() {
    guard case .grace(let deadline) = policy.phase else {
      graceDeadlineScheduler.cancel()
      return
    }

    graceDeadlineScheduler.schedule(at: deadline) { [weak self] in
      guard let self, self.isProtectionEnabled else { return }
      self.requestEvaluation()
    }
  }

  private func enableClosedLidProtection() {
    configureClosedLidSupport(onFailure: .permissionRequired)
  }

  private func repairClosedLidSupport() {
    configureClosedLidSupport(onFailure: .closedLidSetupRepairRequired)
  }

  private func configureClosedLidSupport(onFailure: MenuIssue) {
    guard let closedLidProtection, !isPreparingClosedLid else { return }
    isPreparingClosedLid = true
    menuIssue = nil

    let fail: @MainActor @Sendable (Error) -> Void = { [weak self] error in
      guard let self else { return }
      isPreparingClosedLid = false
      menuIssue = onFailure
      logHiddenError("configure closed-lid protection", error: error)
    }

    let finish: @MainActor @Sendable (PowerProtectSetupState) -> Void = { [weak self] state in
      guard let self else { return }
      if state == .installedAndValid {
        finishClosedLidConfiguration()
        return
      }

      let prepared: @MainActor @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          inspectClosedLidSetup { [weak self] finalState in
            guard let self else { return }
            guard finalState == .installedAndValid else {
              fail(PowerProtectError.setupVerificationFailed)
              return
            }
            finishClosedLidConfiguration()
          }
        case .failure(let error):
          fail(error)
        }
      }

      if usesBackgroundSystemWork {
        backendWorker.prepareClosedLid(completion: prepared)
      } else {
        do {
          try closedLidProtection.prepareClosedLid()
          prepared(.success(()))
        } catch {
          prepared(.failure(error))
        }
      }
    }

    inspectClosedLidSetup(completion: finish)
  }

  private func finishClosedLidConfiguration() {
    guard pendingClosedLidReleaseAfterRepair else {
      setClosedLidMode(true)
      return
    }

    pendingClosedLidReleaseAfterRepair = false
    isPreparingClosedLid = false
    // This is a targeted optional-layer release after setup repair. It must
    // not route through CombinedSleepProtectionBackend.release(), which would
    // also perform a generic mandatory-layer rollback.
    restoreClosedLidFromMenu()
  }

  private func inspectClosedLidSetup(
    completion: @escaping @MainActor @Sendable (PowerProtectSetupState) -> Void
  ) {
    if usesBackgroundSystemWork {
      backendWorker.inspectClosedLidSetup(completion: completion)
    } else {
      completion(
        (backend as? any ClosedLidProtectionInspecting)?.closedLidSetupState ?? .unavailable
      )
    }
  }

  private func setClosedLidMode(_ enabled: Bool) {
    guard closedLidProtection != nil else { return }
    let finish: @MainActor @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
      guard let self else { return }
      isPreparingClosedLid = false
      switch result {
      case .success:
        isClosedLidEnabled = enabled
        protectionStore.saveClosedLidEnabled(enabled)
        menuIssue = nil
        lastBackendRenewAt = .distantPast
        requestEvaluation()
      case .failure(let error):
        menuIssue = .sleepRestoreRequired
        logHiddenError("change closed-lid protection", error: error)
      }
    }

    if usesBackgroundSystemWork {
      backendWorker.setClosedLidEnabled(enabled, completion: finish)
    } else {
      closedLidProtection?.setClosedLidEnabled(enabled)
      finish(.success(()))
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
        lastBackendRenewAt = now()
        menuIssue = nil
      }
    case .failure(let error):
      if operation == .release {
        backendHeld = backend.isHeld
        if isClosedLidSetupRequired(error) {
          pendingClosedLidReleaseAfterRepair = true
        }
        menuIssue =
          error is ClosedLidProtectionError
          ? menuIssue(for: error)
          : .sleepRestoreRequired
        logHiddenError("restore sleep", error: error)
      } else if error is ClosedLidProtectionError {
        // The mandatory IOPM layer remains held when the optional closed-lid
        // layer fails. Keep evaluating it and surface only the optional issue.
        backendHeld = true
        lastBackendRenewAt = now()
        menuIssue = menuIssue(for: error)
        logHiddenError("activate optional closed-lid protection", error: error)
      } else {
        let activationIssue: MenuIssue? =
          (error as? PowerProtectError) == .setupRequired
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

    // Ordinary IOPM recovery must not invoke privileged closed-lid setup.
    release()
  }

  private func restoreClosedLidFromMenu() {
    isResolvingIssue = true
    let finish: @MainActor @Sendable (Result<Void, Error>) -> Void = { [weak self] result in
      guard let self else { return }
      isResolvingIssue = false
      switch result {
      case .success:
        recoveryPending = false
        backendHeld = backend.isHeld
        menuIssue = nil
        if isProtectionEnabled {
          startActivityMonitoring()
          requestEvaluation()
        }
      case .failure(let error):
        if isClosedLidSetupRequired(error) {
          pendingClosedLidReleaseAfterRepair = true
        }
        menuIssue = menuIssue(for: error)
        logHiddenError("restore closed-lid protection from menu", error: error)
      }
    }

    if usesBackgroundSystemWork {
      backendWorker.releaseClosedLid(completion: finish)
    } else if let releaser = backend as? any ClosedLidProtectionReleasing {
      do {
        try releaser.releaseClosedLid()
        finish(.success(()))
      } catch {
        finish(.failure(error))
      }
    } else {
      finish(.success(()))
    }
  }

  private func finishMenuRecovery(_ result: Result<Void, Error>) {
    isResolvingIssue = false
    switch result {
    case .success:
      graceDeadlineScheduler.cancel()
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
      graceDeadlineScheduler.cancel()
      pendingActivationIssue = nil
      menuIssue =
        error is ClosedLidProtectionError
        ? menuIssue(for: error)
        : .sleepRestoreRequired
      logHiddenError("restore sleep from menu", error: error)
    }
  }

  private func migrateClosedLidPreference() {
    guard closedLidPreferenceNeedsMigration else { return }
    closedLidPreferenceNeedsMigration = false
    isPreparingClosedLid = true

    let finish: @MainActor @Sendable (PowerProtectSetupState) -> Void = { [weak self] state in
      guard let self else { return }
      let enabled = state == .installedAndValid
      closedLidProtection?.setClosedLidEnabled(enabled)
      isClosedLidEnabled = enabled
      protectionStore.saveClosedLidEnabled(enabled)
      isPreparingClosedLid = false
      if isProtectionEnabled { startActivityMonitoring() }
      requestEvaluation()
    }

    if usesBackgroundSystemWork {
      backendWorker.inspectClosedLidSetup(completion: finish)
    } else {
      finish((backend as? any ClosedLidProtectionInspecting)?.closedLidSetupState ?? .unavailable)
    }
  }

  private func handleFailedQuit(_ error: Error) {
    quitInProgress = false
    backendOperationInFlight = false
    recoveryPending = false
    backendHeld = backend.isHeld
    if isClosedLidSetupRequired(error) {
      pendingClosedLidReleaseAfterRepair = true
    }
    menuIssue =
      error is ClosedLidProtectionError
      ? menuIssue(for: error)
      : .sleepRestoreRequired

    // A failed quit is recoverable while the app remains alive. Re-arm every
    // observer and the battery callback that quit temporarily stopped.
    batteryStatusProvider.startMonitoring { [weak self] in
      Task { @MainActor in
        self?.requestEvaluation()
      }
    }
    if isProtectionEnabled {
      startActivityMonitoring()
      requestEvaluation()
    }
  }

  private func logHiddenError(_ operation: String, error: Error) {
    NSLog("Codexetine failed to %@: %@", operation, error.localizedDescription)
  }

  private func menuIssue(for error: Error) -> MenuIssue {
    if isClosedLidSetupRequired(error) {
      return .closedLidSetupRepairRequired
    }
    return .closedLidRecoveryRequired
  }

  private func isClosedLidSetupRequired(_ error: Error) -> Bool {
    (error as? ClosedLidProtectionError) == .setupRequired
  }

  @objc
  private func applicationWillTerminate() {
    shutdown()
  }

  private func shutdown() {
    guard started else { return }
    started = false
    graceDeadlineScheduler.cancel()
    batteryStatusProvider.stopMonitoring()
    activityWorker.stop()
    activityWorker.reset()
    removeTerminationObserver()
    let brightnessResult = lidBrightnessController.restoreForExternalTermination()
    if brightnessResult == .exhausted {
      NSLog("Codexetine synchronous brightness restoration exhausted during external termination")
    }

    if let releaser = backend as? any ExternalTerminationReleasing {
      do {
        try releaser.releaseForExternalTermination()
      } catch {
        // The lease/watchdog remains the final recovery path for privileged
        // global state when the narrow IOPM release cannot complete.
        NSLog(
          "Codexetine immediate sleep assertion release failed during external termination: %@",
          error.localizedDescription
        )
      }
    }
  }

  private func removeTerminationObserver() {
    NotificationCenter.default.removeObserver(self)
  }
}
