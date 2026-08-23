import Foundation

/// Serializes Codex file/process inspection away from the main actor.
///
/// FSEvents is the normal wake-up path. Reconciliation is a recovery path for
/// dropped events, a runtime that started before the app, sleep/wake, or a
/// recreated session directory; it is not the activity loop.
// All mutable work and provider access are serialized on `queue`. The tiny
// generation state is separately lock-protected so MainActor delivery never
// has to synchronously enter this queue.
final class CodexActivityWorker: @unchecked Sendable {
  static let activeReconciliationInterval: TimeInterval = 5 * 60
  static let idleReconciliationInterval: TimeInterval = 30 * 60
  static let fallbackReconciliationInterval: TimeInterval = 30

  private let provider: any CodexActivityProviding
  private let generationState = MonitoringGenerationState()
  private let queue = DispatchQueue(
    label: "app.codexnotsleep.codex-activity-worker",
    qos: .utility
  )
  private var reconciliationTimer: DispatchSourceTimer?
  private var refreshScheduled = false
  private var snapshotHandler: (@MainActor @Sendable (CodexActivitySnapshot) -> Void)?
  private(set) var lastScheduledReconciliationInterval: TimeInterval?

  init(provider: any CodexActivityProviding) {
    self.provider = provider
  }

  // Test seam for proving the delivery gate is independent of the worker
  // queue. Production callers only observe snapshots through `start`.
  var currentGenerationForTesting: UInt64? {
    generationState.currentIfStarted()
  }

  func isGenerationCurrentForTesting(_ generation: UInt64) -> Bool {
    generationState.isCurrent(generation)
  }

  func start(
    onSnapshot: @escaping @MainActor @Sendable (CodexActivitySnapshot) -> Void
  ) {
    let generation = generationState.beginIfNeeded()
    queue.async { [weak self] in
      guard let self, self.generationState.isCurrent(generation) else { return }
      self.snapshotHandler = onSnapshot
      guard self.reconciliationTimer == nil else {
        self.scheduleRefresh(for: generation)
        return
      }

      let eventSourceHandler: @Sendable () -> Void = { [weak self] in
        self?.requestRefresh(for: generation)
      }
      self.provider.startMonitoring(onChange: eventSourceHandler)

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.setEventHandler { [weak self] in
        self?.scheduleRefresh(for: generation)
      }
      self.reconciliationTimer = timer
      timer.resume()
      self.scheduleRefresh(for: generation)
    }
  }

  func requestRefresh() {
    queue.async { [weak self] in
      guard let self, let generation = self.generationState.currentIfStarted() else { return }
      self.scheduleRefresh(for: generation)
    }
  }

  private func requestRefresh(for generation: UInt64) {
    queue.async { [weak self] in
      guard let self, self.generationState.isCurrent(generation) else { return }
      self.scheduleRefresh(for: generation)
    }
  }

  func reset() {
    queue.async { [weak self] in
      guard let self else { return }
      self.provider.reset()
    }
  }

  func stop() {
    // Invalidate delivery immediately. The provider and timer are still
    // stopped on their owning queue, but a queued MainActor callback is stale
    // as soon as Stop is requested.
    generationState.stop()
    queue.async { [weak self] in
      guard let self else { return }
      self.reconciliationTimer?.setEventHandler {}
      self.reconciliationTimer?.cancel()
      self.reconciliationTimer = nil
      self.provider.stopMonitoring()
      self.refreshScheduled = false
      self.snapshotHandler = nil
      self.lastScheduledReconciliationInterval = nil
    }
  }

  private func scheduleRefresh(for generation: UInt64? = nil) {
    guard let currentGeneration = generationState.currentIfStarted(), !refreshScheduled else {
      return
    }
    if let generation, generation != currentGeneration { return }
    let refreshGeneration = generation ?? currentGeneration
    refreshScheduled = true
    queue.async { [weak self] in
      guard let self else { return }
      guard self.generationState.isCurrent(refreshGeneration) else { return }
      self.refreshScheduled = false
      let snapshot = self.provider.refresh()
      // Stop → Start may have happened while the provider was parsing or
      // inspecting the filesystem. Do not schedule work or deliver that old
      // result into the new epoch.
      guard self.generationState.isCurrent(refreshGeneration) else { return }
      if self.provider.hasPendingWork {
        self.provider.requestPendingWorkContinuation()
        self.scheduleRefresh(for: refreshGeneration)
      }
      self.scheduleReconciliation(for: snapshot)
      guard let snapshotHandler = self.snapshotHandler else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.generationState.isCurrent(refreshGeneration) else { return }
        snapshotHandler(snapshot)
      }
    }
  }

  private func scheduleReconciliation(for snapshot: CodexActivitySnapshot) {
    guard let timer = reconciliationTimer, generationState.isStarted else { return }
    let interval: TimeInterval
    if !provider.isEventSourceHealthy {
      interval = Self.fallbackReconciliationInterval
    } else {
      switch snapshot {
      case .idle:
        interval = Self.idleReconciliationInterval
      case .active:
        interval = Self.activeReconciliationInterval
      case .unavailable:
        interval = Self.fallbackReconciliationInterval
      }
    }
    lastScheduledReconciliationInterval = interval
    timer.schedule(
      deadline: .now() + interval,
      repeating: .never,
      leeway: .seconds(5)
    )
  }
}

/// Keeps only the hot start epoch behind a tiny lock. It is intentionally
/// independent from the activity worker queue so snapshot delivery can reject
/// stale work without waiting for parsing or provider I/O.
final class MonitoringGenerationState: @unchecked Sendable {
  private let lock = NSLock()
  private var monitoringGeneration: UInt64 = 0
  private var started = false

  func beginIfNeeded() -> UInt64 {
    lock.withLock {
      guard !started else { return monitoringGeneration }
      monitoringGeneration &+= 1
      started = true
      return monitoringGeneration
    }
  }

  func stop() {
    lock.withLock {
      monitoringGeneration &+= 1
      started = false
    }
  }

  func currentIfStarted() -> UInt64? {
    lock.withLock { started ? monitoringGeneration : nil }
  }

  var isStarted: Bool {
    lock.withLock { started }
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    lock.withLock { started && monitoringGeneration == generation }
  }
}
