import Foundation

/// Serializes Codex file/process inspection away from the main actor.
///
/// FSEvents is the normal wake-up path. The 30-second reconciliation is only
/// a recovery path for a dropped event, a runtime that started before the app,
/// sleep/wake, or a recreated session directory; it is not the activity loop.
// All mutable state and provider access are serialized on `queue`.
final class CodexActivityWorker: @unchecked Sendable {
  static let reconciliationInterval: TimeInterval = 30

  private let provider: any CodexActivityProviding
  private let queue = DispatchQueue(
    label: "app.codexnotsleep.codex-activity-worker",
    qos: .utility
  )
  private var reconciliationTimer: DispatchSourceTimer?
  private var isStarted = false
  private var refreshScheduled = false
  private var snapshotHandler:
    (@MainActor @Sendable (CodexActivitySnapshot) -> Void)?

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
      self.provider.startMonitoring { [weak self] in
        self?.requestRefresh()
      }

      let timer = DispatchSource.makeTimerSource(queue: self.queue)
      timer.schedule(
        deadline: .now() + Self.reconciliationInterval,
        repeating: Self.reconciliationInterval,
        leeway: .seconds(5)
      )
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
    }
  }

  private func scheduleRefresh() {
    guard isStarted, !refreshScheduled else { return }
    refreshScheduled = true
    queue.async { [weak self] in
      guard let self, self.isStarted else { return }
      self.refreshScheduled = false
      let snapshot = self.provider.refresh()
      guard let snapshotHandler = self.snapshotHandler else { return }
      DispatchQueue.main.async {
        snapshotHandler(snapshot)
      }
    }
  }
}
