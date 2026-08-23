import Foundation

/// Serializes Codex file/process inspection away from the main actor.
///
/// FSEvents is the normal wake-up path. Reconciliation is a recovery path for
/// dropped events, a runtime that started before the app, sleep/wake, or a
/// recreated session directory; it is not the activity loop.
// All mutable state and provider access are serialized on `queue`.
final class CodexActivityWorker: @unchecked Sendable {
  static let activeReconciliationInterval: TimeInterval = 5 * 60
  static let idleReconciliationInterval: TimeInterval = 30 * 60
  static let fallbackReconciliationInterval: TimeInterval = 30

  private let provider: any CodexActivityProviding
  private let queue = DispatchQueue(
    label: "app.codexnotsleep.codex-activity-worker",
    qos: .utility
  )
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let queueToken: UInt8 = 1
  private var reconciliationTimer: DispatchSourceTimer?
  private var isStarted = false
  private var monitoringGeneration: UInt64 = 0
  private var refreshScheduled = false
  private var snapshotHandler: (@MainActor @Sendable (CodexActivitySnapshot) -> Void)?
  private(set) var lastScheduledReconciliationInterval: TimeInterval?

  init(provider: any CodexActivityProviding) {
    self.provider = provider
    queue.setSpecific(key: queueKey, value: queueToken)
  }

  func start(
    onSnapshot: @escaping @MainActor @Sendable (CodexActivitySnapshot) -> Void
  ) {
    queue.async { [weak self] in
      guard let self else { return }
      self.snapshotHandler = onSnapshot
      guard !self.isStarted else {
        self.scheduleRefresh()
        return
      }

      self.monitoringGeneration &+= 1
      let generation = self.monitoringGeneration
      self.isStarted = true
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
      self.scheduleRefresh()
    }
  }

  func requestRefresh() {
    queue.async { [weak self] in
      self?.scheduleRefresh()
    }
  }

  private func requestRefresh(for generation: UInt64) {
    queue.async { [weak self] in
      guard let self, self.isStarted, self.monitoringGeneration == generation else { return }
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
    queue.async { [weak self] in
      guard let self else { return }
      self.monitoringGeneration &+= 1
      self.isStarted = false
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
    guard isStarted, !refreshScheduled else { return }
    if let generation, generation != monitoringGeneration { return }
    let refreshGeneration = monitoringGeneration
    refreshScheduled = true
    queue.async { [weak self] in
      guard let self else { return }
      guard self.isStarted, self.monitoringGeneration == refreshGeneration else {
        if self.monitoringGeneration == refreshGeneration {
          self.refreshScheduled = false
        }
        return
      }
      self.refreshScheduled = false
      let snapshot = self.provider.refresh()
      if self.provider.hasPendingWork {
        self.provider.requestPendingWorkContinuation()
        self.scheduleRefresh()
      }
      self.scheduleReconciliation(for: snapshot)
      guard let snapshotHandler = self.snapshotHandler else { return }
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isGenerationCurrent(refreshGeneration) else { return }
        snapshotHandler(snapshot)
      }
    }
  }

  private func isGenerationCurrent(_ generation: UInt64) -> Bool {
    if DispatchQueue.getSpecific(key: queueKey) == queueToken {
      return monitoringGeneration == generation
    }
    return queue.sync { monitoringGeneration == generation && isStarted }
  }

  private func scheduleReconciliation(for snapshot: CodexActivitySnapshot) {
    guard let timer = reconciliationTimer, isStarted else { return }
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
