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
  private var reconciliationTimer: DispatchSourceTimer?
  private var isStarted = false
  private var refreshScheduled = false
  private var snapshotHandler: (@MainActor @Sendable (CodexActivitySnapshot) -> Void)?
  private var eventSourceHandler: (@Sendable () -> Void)?
  private(set) var lastScheduledReconciliationInterval: TimeInterval?

  init(provider: any CodexActivityProviding) {
    self.provider = provider
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

      self.isStarted = true
      let eventSourceHandler: @Sendable () -> Void = { [weak self] in
        self?.requestRefresh()
      }
      self.eventSourceHandler = eventSourceHandler
      self.provider.startMonitoring(onChange: eventSourceHandler)

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.setEventHandler { [weak self] in
        self?.scheduleRefresh()
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

  func reset() {
    queue.async { [weak self] in
      guard let self else { return }
      self.provider.reset()
    }
  }

  func stop() {
    queue.async { [weak self] in
      guard let self else { return }
      self.isStarted = false
      self.reconciliationTimer?.setEventHandler {}
      self.reconciliationTimer?.cancel()
      self.reconciliationTimer = nil
      self.provider.stopMonitoring()
      self.refreshScheduled = false
      self.snapshotHandler = nil
      self.eventSourceHandler = nil
      self.lastScheduledReconciliationInterval = nil
    }
  }

  private func scheduleRefresh() {
    guard isStarted, !refreshScheduled else { return }
    refreshScheduled = true
    queue.async { [weak self] in
      guard let self, self.isStarted else { return }
      self.refreshScheduled = false
      let snapshot = self.provider.refresh()
      if self.provider.hasPendingWork {
        self.provider.requestPendingWorkContinuation()
        self.scheduleRefresh()
      }
      if !self.provider.isEventSourceHealthy, let eventSourceHandler = self.eventSourceHandler {
        self.provider.startMonitoring(onChange: eventSourceHandler)
      }
      self.scheduleReconciliation(for: snapshot)
      guard let snapshotHandler = self.snapshotHandler else { return }
      DispatchQueue.main.async {
        snapshotHandler(snapshot)
      }
    }
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
