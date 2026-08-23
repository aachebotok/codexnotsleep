import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct CodexActivityWorkerTests {
  @Test
  func eventWakeupRefreshesAndCoalescesWithoutShortPolling() async throws {
    let provider = WorkerActivityProvider(snapshot: .active(turnCount: 1))
    let worker = CodexActivityWorker(provider: provider)
    var received: [CodexActivitySnapshot] = []

    worker.start { snapshot in
      received.append(snapshot)
    }
    provider.emitChange()
    provider.emitChange()

    for _ in 0..<20 where received.isEmpty {
      try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(80))
    worker.stop()
    try await Task.sleep(for: .milliseconds(20))

    #expect(received.contains(.active(turnCount: 1)))
    #expect(provider.startCount == 1)
    #expect(provider.stopCount == 1)
    #expect(provider.refreshCount <= 2)
  }

  @Test
  func idleReconciliationBacksOffAndPendingBacklogIsRequeued() async throws {
    let provider = WorkerActivityProvider(snapshot: .active(turnCount: 1))
    provider.setRefreshSequence([.active(turnCount: 1), .idle])
    let worker = CodexActivityWorker(provider: provider)
    var received: [CodexActivitySnapshot] = []

    worker.start { snapshot in
      received.append(snapshot)
    }

    for _ in 0..<30 where !received.contains(.idle) {
      try await Task.sleep(for: .milliseconds(10))
    }
    let scheduledInterval = worker.lastScheduledReconciliationInterval
    worker.stop()

    #expect(received.contains(.idle))
    #expect(provider.refreshCount >= 2)
    #expect(provider.continuationRequestCount >= 1)
    #expect(scheduledInterval == CodexActivityWorker.idleReconciliationInterval)
    #expect(CodexActivityWorker.activeReconciliationInterval >= 5 * 60)
    #expect(CodexActivityWorker.idleReconciliationInterval >= 15 * 60)
    #expect(CodexActivityWorker.fallbackReconciliationInterval <= 60)
  }

  @Test
  func unhealthyEventSourceUsesFallbackCadenceWithoutWorkerRestart() async throws {
    let provider = WorkerActivityProvider(snapshot: .active(turnCount: 1))
    provider.isEventSourceHealthy = false
    let worker = CodexActivityWorker(provider: provider)
    worker.start { _ in }

    for _ in 0..<30
    where worker.lastScheduledReconciliationInterval
      != CodexActivityWorker.fallbackReconciliationInterval
    {
      try await Task.sleep(for: .milliseconds(10))
    }
    let scheduledInterval = worker.lastScheduledReconciliationInterval
    provider.emitChange()
    provider.emitChange()
    try await Task.sleep(for: .milliseconds(40))
    worker.stop()

    #expect(scheduledInterval == CodexActivityWorker.fallbackReconciliationInterval)
    #expect(provider.startCount == 1)
  }
}

private final class WorkerActivityProvider: CodexActivityProviding, @unchecked Sendable {
  private let lock = NSLock()
  private var storedSnapshot: CodexActivitySnapshot
  private var refreshSequence: [CodexActivitySnapshot] = []
  private var changeHandler: (@Sendable () -> Void)?
  var isEventSourceHealthy = true
  private(set) var startCount = 0
  private(set) var stopCount = 0
  private(set) var refreshCount = 0
  private(set) var continuationRequestCount = 0

  init(snapshot: CodexActivitySnapshot) {
    storedSnapshot = snapshot
  }

  var snapshot: CodexActivitySnapshot {
    lock.lock()
    defer { lock.unlock() }
    return storedSnapshot
  }

  var hasPendingWork: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !refreshSequence.isEmpty
  }

  func refresh() -> CodexActivitySnapshot {
    lock.lock()
    defer { lock.unlock() }
    refreshCount += 1
    if !refreshSequence.isEmpty {
      storedSnapshot = refreshSequence.removeFirst()
    }
    return storedSnapshot
  }

  func requestPendingWorkContinuation() {
    lock.lock()
    continuationRequestCount += 1
    lock.unlock()
  }

  func setRefreshSequence(_ snapshots: [CodexActivitySnapshot]) {
    lock.lock()
    refreshSequence = snapshots
    lock.unlock()
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    lock.lock()
    changeHandler = onChange
    startCount += 1
    lock.unlock()
  }

  func stopMonitoring() {
    lock.lock()
    changeHandler = nil
    stopCount += 1
    lock.unlock()
  }

  func emitChange() {
    lock.lock()
    let handler = changeHandler
    lock.unlock()
    handler?()
  }
}
