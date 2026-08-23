import CoreServices
import Darwin
import Foundation

enum CodexActivitySnapshot: Equatable, Sendable {
  case idle
  case active(turnCount: Int)
  case unavailable(protectConservatively: Bool)

  var effectiveActiveCount: Int {
    switch self {
    case .idle:
      0
    case .active(let turnCount):
      max(turnCount, 1)
    case .unavailable(let protectConservatively):
      protectConservatively ? 1 : 0
    }
  }

  var usesFallback: Bool {
    if case .unavailable = self { return true }
    return false
  }
}

protocol CodexActivityProviding: AnyObject {
  var snapshot: CodexActivitySnapshot { get }
  var hasPendingWork: Bool { get }
  var isEventSourceHealthy: Bool { get }

  @discardableResult
  func refresh() -> CodexActivitySnapshot

  func reset()
  func requestPendingWorkContinuation()

  /// Starts the event source used by the live app. Test doubles can use the
  /// default no-op implementation and continue to drive `refresh()` directly.
  func startMonitoring(onChange: @escaping @Sendable () -> Void)
  func stopMonitoring()
}

extension CodexActivityProviding {
  var hasPendingWork: Bool { false }
  var isEventSourceHealthy: Bool { true }
  func reset() {}
  func requestPendingWorkContinuation() {}
  func startMonitoring(onChange: @escaping @Sendable () -> Void) {}
  func stopMonitoring() {}
}

struct CodexOpenSessionFile: Equatable, Sendable {
  let url: URL
  let ownerStartedAt: Date
}

struct CodexOpenSessionInventory: Equatable, Sendable {
  let hasCodexRuntime: Bool
  let files: [CodexOpenSessionFile]
  let isReliable: Bool
}

protocol CodexOpenSessionLocating {
  func locateOpenSessions() throws -> CodexOpenSessionInventory
}

struct CodexRuntimeProcess: Equatable, Sendable {
  let processID: pid_t
  let startedAt: Date
}

protocol CodexProcessInspecting {
  func currentUserCodexProcesses(userID: uid_t) -> [CodexRuntimeProcess]?
  func openFilePaths(processID: pid_t) -> [String]?
}

enum CodexOpenSessionLocatorError: LocalizedError {
  case processInventoryUnavailable

  var errorDescription: String? {
    switch self {
    case .processInventoryUnavailable:
      "Couldn't read Codex processes"
    }
  }
}

struct CodexLocatorMetrics: Equatable, Sendable {
  var processTableScans = 0
  var fileDescriptorScans = 0
  var directoryScans = 0
  var directoryEntriesVisited = 0
  var discoveredPathCount = 0
}

struct CodexMonitorMetrics: Equatable, Sendable {
  var refreshes = 0
  var lifecycleChunkReads = 0
  var trackedStateCount = 0
}

struct CodexSessionFileChanges {
  var paths = Set<String>()
  var requiresFullScan = false
}

struct FSEventsObserverConfiguration: Equatable, Sendable {
  let latency: TimeInterval
  let usesNoDefer: Bool

  static let current = FSEventsObserverConfiguration(
    latency: 0.1,
    usesNoDefer: true
  )
}

protocol CodexSessionFileChangeObserving: AnyObject {
  func takeChanges() -> CodexSessionFileChanges
  var isEventSourceHealthy: Bool { get }
}

extension CodexSessionFileChangeObserving {
  var isEventSourceHealthy: Bool { true }
}

private protocol CodexSessionFileChangeNotifying: AnyObject {
  func start(onChange: @escaping @Sendable () -> Void)
  func stop()
  var isEventSourceHealthy: Bool { get }
}

final class FSEventsCodexSessionFileChangeObserver: @unchecked Sendable,
  CodexSessionFileChangeObserving, CodexSessionFileChangeNotifying
{
  private let sessionRoot: URL
  private let configuration: FSEventsObserverConfiguration
  private let queue = DispatchQueue(
    label: "app.codexnotsleep.codex-session-events",
    qos: .utility
  )
  private let queueKey = DispatchSpecificKey<UInt8>()
  private let queueToken: UInt8 = 1
  private let startStreamOverride: (() -> Bool)?
  private let stopStreamOverride: (() -> Void)?
  private let retryDelays: [TimeInterval]
  private var pendingChanges = CodexSessionFileChanges()
  private var callbackCount = 0
  private var stream: FSEventStreamRef?
  private var changeHandler: (@Sendable () -> Void)?
  private var isStarted = false
  private var wantsMonitoring = false
  private var eventSourceHealthy = true
  private var retryAttempt = 0
  private var retryWorkItem: DispatchWorkItem?

  private static let defaultRetryDelays: [TimeInterval] = [1, 2, 4, 8, 16, 30]

  init(
    sessionRoot: URL,
    configuration: FSEventsObserverConfiguration = .current,
    startStream: (() -> Bool)? = nil,
    stopStream: (() -> Void)? = nil,
    retryDelays: [TimeInterval] = FSEventsCodexSessionFileChangeObserver.defaultRetryDelays
  ) {
    self.sessionRoot = sessionRoot
    self.configuration = configuration
    startStreamOverride = startStream
    stopStreamOverride = stopStream
    self.retryDelays = retryDelays.isEmpty ? Self.defaultRetryDelays : retryDelays
    queue.setSpecific(key: queueKey, value: queueToken)
    queue.sync { createStreamLocked() }
  }

  var isEventSourceHealthy: Bool {
    onOwnerQueue { eventSourceHealthy }
  }

  private func onOwnerQueue<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: queueKey) == queueToken {
      return body()
    }
    return queue.sync(execute: body)
  }

  private func createStreamLocked() {
    guard startStreamOverride == nil else { return }
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    var flags =
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot)
    if configuration.usesNoDefer {
      flags |= FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
    }
    stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      Self.callback,
      &context,
      [sessionRoot.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      configuration.latency,
      flags
    )
    if let stream {
      FSEventStreamSetDispatchQueue(stream, queue)
    } else {
      markStartFailureLocked()
    }
  }

  deinit {
    if DispatchQueue.getSpecific(key: queueKey) == queueToken {
      disposeLocked()
    } else {
      queue.sync { disposeLocked() }
    }
  }

  func start(onChange: @escaping @Sendable () -> Void) {
    onOwnerQueue {
      changeHandler = onChange
      wantsMonitoring = true
      guard !isStarted else { return }
      if retryWorkItem == nil, retryAttempt >= retryDelays.count {
        retryAttempt = 0
      }
      startStreamLocked()
    }
  }

  func stop() {
    onOwnerQueue { disposeLocked(clearPendingChanges: false) }
  }

  func takeChanges() -> CodexSessionFileChanges {
    onOwnerQueue {
      let changes = pendingChanges
      pendingChanges = CodexSessionFileChanges()
      return changes
    }
  }

  var observedCallbackCount: Int {
    onOwnerQueue { callbackCount }
  }

  static func requiresFullScan(for flags: FSEventStreamEventFlags) -> Bool {
    flags
      & FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs
          | kFSEventStreamEventFlagUserDropped
          | kFSEventStreamEventFlagKernelDropped
          | kFSEventStreamEventFlagEventIdsWrapped
          | kFSEventStreamEventFlagRootChanged
      ) != 0
  }

  private func receive(paths: [String], flags: [FSEventStreamEventFlags]) {
    queue.async { [weak self] in
      guard let self else { return }
      callbackCount += 1
      if paths.count != flags.count {
        pendingChanges.requiresFullScan = true
      }
      for index in flags.indices {
        let eventFlags = flags[index]
        if Self.requiresFullScan(for: eventFlags) {
          pendingChanges.requiresFullScan = true
        }
        if index < paths.count {
          pendingChanges.paths.insert(paths[index])
        }
      }
      changeHandler?()
      if Self.requiresRootRestart(flags: flags) {
        restartStreamLocked()
      }
    }
  }

  private static func requiresRootRestart(flags: [FSEventStreamEventFlags]) -> Bool {
    flags.contains {
      $0 & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0
    }
  }

  private func restartStreamLocked() {
    guard wantsMonitoring else { return }
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    if startStreamOverride == nil { createStreamLocked() }
    isStarted = false
    startStreamLocked()
  }

  private func startStreamLocked() {
    guard wantsMonitoring, !isStarted else { return }
    let didStart: Bool
    if let startStreamOverride {
      didStart = startStreamOverride()
    } else if let stream {
      didStart = FSEventStreamStart(stream)
    } else {
      didStart = false
    }

    guard didStart else {
      markStartFailureLocked()
      return
    }

    isStarted = true
    eventSourceHealthy = true
    retryAttempt = 0
    cancelRetryLocked()
  }

  private func markStartFailureLocked() {
    isStarted = false
    eventSourceHealthy = false
    pendingChanges.requiresFullScan = true
    changeHandler?()
    scheduleRetryLocked()
  }

  private func scheduleRetryLocked() {
    guard wantsMonitoring, retryWorkItem == nil, retryAttempt < retryDelays.count else {
      return
    }
    let delay = max(retryDelays[retryAttempt], 0.01)
    retryAttempt += 1
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.retryWorkItem = nil
      self.startStreamLocked()
    }
    retryWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private func cancelRetryLocked() {
    retryWorkItem?.cancel()
    retryWorkItem = nil
  }

  private func disposeLocked(clearPendingChanges: Bool = true) {
    wantsMonitoring = false
    cancelRetryLocked()
    if let stream {
      if isStarted { FSEventStreamStop(stream) }
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
      self.stream = nil
    }
    stopStreamOverride?()
    isStarted = false
    eventSourceHealthy = true
    retryAttempt = 0
    changeHandler = nil
    if clearPendingChanges {
      pendingChanges = CodexSessionFileChanges()
    }
  }

  private static let callback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
    guard let callbackInfo else { return }
    let observer = Unmanaged<FSEventsCodexSessionFileChangeObserver>
      .fromOpaque(callbackInfo)
      .takeUnretainedValue()
    let pathArray = unsafeBitCast(eventPaths, to: NSArray.self)
    let paths = pathArray as? [String] ?? []
    let flags = (0..<eventCount).map { eventFlags[$0] }
    observer.receive(paths: paths, flags: flags)
  }
}

protocol CodexOpenSessionEventSource: AnyObject {
  var isEventSourceHealthy: Bool { get }
  func startMonitoring(onChange: @escaping @Sendable () -> Void)
  func stopMonitoring()
}

private protocol CodexKnownFileContinuationRequesting: AnyObject {
  func requestKnownFileContinuation()
}

final class LibprocCodexOpenSessionLocator: CodexOpenSessionLocating,
  CodexOpenSessionEventSource, CodexKnownFileContinuationRequesting
{
  private static let discoveryInterval: TimeInterval = 5 * 60
  private static let processStartTolerance: TimeInterval = 5
  private static let maximumDiscoveredPaths = 256
  private static let discoveredPathLifetime: TimeInterval = 30 * 60
  private static let maximumEnumerationEntries = 2_048
  private static let maximumEnumerationDepth = 6

  private let sessionRoot: URL
  private let userID: uid_t
  private let processInspector: any CodexProcessInspecting
  private let fileManager: FileManager
  private let minimumDiscoveryInterval: TimeInterval
  private let now: () -> Date
  private let changeObserver: any CodexSessionFileChangeObserving
  private var discoveredPaths: [String: Date] = [:]
  private var discoveryWasReliable = true
  private var discoveredForRuntimeStartedAt: Date?
  private var lastDiscoveryAt = Date.distantPast
  private var cachedInventory: CodexOpenSessionInventory?
  private var continuationRequested = false
  private(set) var metrics = CodexLocatorMetrics()

  private struct EnumerationItem {
    let url: URL
    let depth: Int
  }

  init(
    sessionRoot: URL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: ".codex/sessions"),
    userID: uid_t = getuid(),
    processInspector: any CodexProcessInspecting = LibprocCodexProcessInspector(),
    fileManager: FileManager = .default,
    minimumDiscoveryInterval: TimeInterval = LibprocCodexOpenSessionLocator.discoveryInterval,
    now: @escaping () -> Date = Date.init,
    changeObserver: (any CodexSessionFileChangeObserving)? = nil
  ) {
    self.sessionRoot = sessionRoot.standardizedFileURL.resolvingSymlinksInPath()
    self.userID = userID
    self.processInspector = processInspector
    self.fileManager = fileManager
    self.minimumDiscoveryInterval = minimumDiscoveryInterval
    self.now = now
    self.changeObserver =
      changeObserver ?? FSEventsCodexSessionFileChangeObserver(sessionRoot: self.sessionRoot)
  }

  var isEventSourceHealthy: Bool {
    (changeObserver as? any CodexSessionFileChangeNotifying)?.isEventSourceHealthy ?? true
  }

  func requestKnownFileContinuation() {
    continuationRequested = true
  }

  func locateOpenSessions() throws -> CodexOpenSessionInventory {
    let changes = changeObserver.takeChanges()
    let shouldContinueKnownFiles = continuationRequested
    continuationRequested = false
    if shouldContinueKnownFiles, let cachedInventory,
      canUseCachedInventoryForContinuation(cachedInventory, changes: changes)
    {
      let inventory = inventoryAfterKnownFileChanges(cachedInventory, changes: changes)
      self.cachedInventory = inventory
      return inventory
    }
    if let cachedInventory, canUseCachedInventory(for: changes) {
      let inventory = inventoryAfterKnownFileChanges(cachedInventory, changes: changes)
      self.cachedInventory = inventory
      return inventory
    }

    metrics.processTableScans += 1
    guard let codexProcesses = processInspector.currentUserCodexProcesses(userID: userID) else {
      throw CodexOpenSessionLocatorError.processInventoryUnavailable
    }
    guard !codexProcesses.isEmpty else {
      resetDiscovery()
      let inventory = CodexOpenSessionInventory(hasCodexRuntime: false, files: [], isReliable: true)
      cachedInventory = inventory
      return inventory
    }

    let runtimeStartedAt = codexProcesses.map(\.startedAt).min() ?? .distantPast
    applyFileChanges(changes, runtimeStartedAt: runtimeStartedAt)
    refreshDiscoveredPathsIfNeeded(runtimeStartedAt: runtimeStartedAt)

    var ownersByPath: [String: Date] = [:]
    var readableProcessCount = 0

    for process in codexProcesses {
      metrics.fileDescriptorScans += 1
      guard let paths = processInspector.openFilePaths(processID: process.processID) else {
        continue
      }
      readableProcessCount += 1

      for path in paths where isSessionJSONL(path) {
        if let existing = ownersByPath[path] {
          ownersByPath[path] = min(existing, process.startedAt)
        } else {
          ownersByPath[path] = process.startedAt
        }
      }
    }

    for path in discoveredPaths.keys {
      if let existing = ownersByPath[path] {
        ownersByPath[path] = min(existing, runtimeStartedAt)
      } else {
        ownersByPath[path] = runtimeStartedAt
      }
    }

    let files = ownersByPath.map { path, ownerStartedAt in
      CodexOpenSessionFile(
        url: URL(fileURLWithPath: path).standardizedFileURL,
        ownerStartedAt: ownerStartedAt
      )
    }
    .sorted { $0.url.path < $1.url.path }

    let inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: files,
      isReliable: readableProcessCount == codexProcesses.count && discoveryWasReliable
    )
    cachedInventory = inventory
    return inventory
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    (changeObserver as? CodexSessionFileChangeNotifying)?.start(onChange: onChange)
  }

  func stopMonitoring() {
    (changeObserver as? CodexSessionFileChangeNotifying)?.stop()
  }

  private func canUseCachedInventoryForContinuation(
    _ inventory: CodexOpenSessionInventory,
    changes: CodexSessionFileChanges
  ) -> Bool {
    guard !changes.requiresFullScan else { return false }
    guard !changes.paths.isEmpty || !inventory.files.isEmpty else { return false }
    let knownPaths = Set(inventory.files.map { $0.url.standardizedFileURL.path })
    return changes.paths.allSatisfy { path in
      let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      return isSessionJSONL(normalizedPath) && knownPaths.contains(normalizedPath)
    }
  }

  private func canUseCachedInventory(for changes: CodexSessionFileChanges) -> Bool {
    guard let cachedInventory, cachedInventory.hasCodexRuntime else { return false }
    guard !changes.requiresFullScan, !changes.paths.isEmpty else { return false }
    let knownPaths = Set(cachedInventory.files.map { $0.url.standardizedFileURL.path })
    return changes.paths.allSatisfy { path in
      let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      return isSessionJSONL(normalizedPath) && knownPaths.contains(normalizedPath)
    }
  }

  private func inventoryAfterKnownFileChanges(
    _ inventory: CodexOpenSessionInventory,
    changes: CodexSessionFileChanges
  ) -> CodexOpenSessionInventory {
    let deletedPaths = Set(
      changes.paths
        .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        .filter { !fileManager.fileExists(atPath: $0) }
    )
    guard !deletedPaths.isEmpty else { return inventory }
    return CodexOpenSessionInventory(
      hasCodexRuntime: inventory.hasCodexRuntime,
      files: inventory.files.filter {
        !deletedPaths.contains($0.url.standardizedFileURL.path)
      },
      isReliable: inventory.isReliable
    )
  }

  private func applyFileChanges(
    _ changes: CodexSessionFileChanges,
    runtimeStartedAt: Date
  ) {
    if changes.requiresFullScan {
      lastDiscoveryAt = .distantPast
    }
    let currentTime = now()
    let cutoff = runtimeStartedAt.addingTimeInterval(-Self.processStartTolerance)
    for path in changes.paths where isSessionJSONL(path) {
      let url = URL(fileURLWithPath: path).standardizedFileURL
      do {
        let values = try url.resourceValues(
          forKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        if values.isRegularFile == true,
          let modifiedAt = values.contentModificationDate,
          modifiedAt >= cutoff
        {
          discoveredPaths[url.path] = currentTime
        } else {
          discoveredPaths.removeValue(forKey: url.path)
        }
      } catch {
        if !fileManager.fileExists(atPath: url.path) {
          discoveredPaths.removeValue(forKey: url.path)
        } else {
          discoveryWasReliable = false
        }
      }
    }
    trimDiscoveredPaths(at: currentTime)
    metrics.discoveredPathCount = discoveredPaths.count
  }

  private func refreshDiscoveredPathsIfNeeded(runtimeStartedAt: Date) {
    let currentTime = now()
    let runtimeChanged = discoveredForRuntimeStartedAt != runtimeStartedAt
    guard
      runtimeChanged
        || currentTime.timeIntervalSince(lastDiscoveryAt) >= minimumDiscoveryInterval
    else { return }

    let cutoff = runtimeStartedAt.addingTimeInterval(-Self.processStartTolerance)
    let resourceKeys: [URLResourceKey] = [
      .contentModificationDateKey, .isRegularFileKey, .isDirectoryKey,
    ]
    var paths: [String: Date] = [:]
    var wasReliable = true
    metrics.directoryScans += 1
    metrics.directoryEntriesVisited = 0
    guard fileManager.fileExists(atPath: sessionRoot.path) else {
      discoveredPaths = [:]
      metrics.discoveredPathCount = 0
      discoveryWasReliable = wasReliable
      discoveredForRuntimeStartedAt = runtimeStartedAt
      lastDiscoveryAt = currentTime
      return
    }

    var pending = [EnumerationItem(url: sessionRoot, depth: 0)]
    while !pending.isEmpty {
      guard metrics.directoryEntriesVisited < Self.maximumEnumerationEntries else {
        wasReliable = false
        break
      }
      let item = pending.removeFirst()
      metrics.directoryEntriesVisited += 1

      guard let values = try? item.url.resourceValues(forKeys: Set(resourceKeys)) else {
        wasReliable = false
        continue
      }

      if values.isDirectory == true {
        guard item.depth < Self.maximumEnumerationDepth else {
          wasReliable = false
          continue
        }
        if shouldPruneDirectory(item.url, cutoff: cutoff, currentTime: currentTime) {
          continue
        }
        do {
          let children = try fileManager.contentsOfDirectory(
            at: item.url,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
          )
          pending.append(
            contentsOf: children.map {
              EnumerationItem(url: $0, depth: item.depth + 1)
            })
        } catch {
          wasReliable = false
        }
        continue
      }

      guard isSessionJSONL(item.url.path), values.isRegularFile == true,
        let modifiedAt = values.contentModificationDate,
        modifiedAt >= cutoff,
        modifiedAt <= currentTime.addingTimeInterval(Self.processStartTolerance)
      else { continue }
      paths[item.url.standardizedFileURL.path] = modifiedAt
    }

    if !fileManager.fileExists(atPath: sessionRoot.path) {
      wasReliable = false
    }

    discoveredPaths =
      paths
      .filter { currentTime.timeIntervalSince($0.value) < Self.discoveredPathLifetime }
      .sorted { $0.value > $1.value }
      .prefix(Self.maximumDiscoveredPaths)
      .reduce(into: [:]) { $0[$1.key] = $1.value }
    metrics.discoveredPathCount = discoveredPaths.count
    discoveryWasReliable = wasReliable
    discoveredForRuntimeStartedAt = runtimeStartedAt
    lastDiscoveryAt = currentTime
  }

  private func shouldPruneDirectory(
    _ url: URL,
    cutoff: Date,
    currentTime: Date
  ) -> Bool {
    if let partitionDate = datePartitionStart(for: url) {
      return partitionDate < Calendar.current.startOfDay(for: cutoff)
    }
    guard
      let values = try? url.resourceValues(
        forKeys: [.contentModificationDateKey]
      ), let modifiedAt = values.contentModificationDate
    else {
      return false
    }
    return modifiedAt < cutoff
      && currentTime.timeIntervalSince(modifiedAt) > Self.discoveredPathLifetime
  }

  private func datePartitionStart(for url: URL) -> Date? {
    let components = url.pathComponents
    guard components.count >= 3 else { return nil }
    let calendar = Calendar(identifier: .gregorian)
    for index in stride(from: components.count - 3, through: 0, by: -1) {
      guard
        let year = Int(components[index]), year >= 2000, year <= 3000,
        let month = Int(components[index + 1]), (1...12).contains(month),
        let day = Int(components[index + 2]), (1...31).contains(day)
      else { continue }
      return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
    return nil
  }

  private func resetDiscovery() {
    discoveredPaths.removeAll()
    discoveryWasReliable = true
    discoveredForRuntimeStartedAt = nil
    lastDiscoveryAt = .distantPast
    cachedInventory = nil
    metrics.discoveredPathCount = 0
  }

  private func trimDiscoveredPaths(at currentTime: Date) {
    discoveredPaths =
      discoveredPaths
      .filter { currentTime.timeIntervalSince($0.value) < Self.discoveredPathLifetime }
      .sorted { $0.value > $1.value }
      .prefix(Self.maximumDiscoveredPaths)
      .reduce(into: [:]) { $0[$1.key] = $1.value }
    metrics.discoveredPathCount = discoveredPaths.count
  }

  private func isSessionJSONL(_ path: String) -> Bool {
    let rootPath = sessionRoot.path.hasSuffix("/") ? sessionRoot.path : sessionRoot.path + "/"
    let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
      .path
    return standardizedPath.hasPrefix(rootPath)
      && standardizedPath.hasSuffix(".jsonl")
      && !standardizedPath.contains("/archived_sessions/")
  }
}

struct LibprocCodexProcessInspector: CodexProcessInspecting {
  func currentUserCodexProcesses(userID: uid_t) -> [CodexRuntimeProcess]? {
    processTable()?.compactMap { process in
      guard
        process.kp_eproc.e_pcred.p_ruid == userID,
        process.kp_proc.p_stat != SZOMB,
        processName(process) == "codex"
      else { return nil }

      return CodexRuntimeProcess(
        processID: process.kp_proc.p_pid,
        startedAt: Date(
          timeIntervalSince1970: TimeInterval(process.kp_proc.p_starttime.tv_sec)
            + TimeInterval(process.kp_proc.p_starttime.tv_usec) / 1_000_000
        )
      )
    }
  }

  func openFilePaths(processID: pid_t) -> [String]? {
    let requiredBytes = proc_pidinfo(processID, PROC_PIDLISTFDS, 0, nil, 0)
    let stride = MemoryLayout<proc_fdinfo>.stride
    guard requiredBytes >= stride else { return nil }

    var descriptors = [proc_fdinfo](
      repeating: proc_fdinfo(),
      count: Int(requiredBytes) / stride + 16
    )
    let bufferBytes = descriptors.count * stride
    let readBytes = descriptors.withUnsafeMutableBytes { buffer in
      proc_pidinfo(
        processID,
        PROC_PIDLISTFDS,
        0,
        buffer.baseAddress,
        Int32(bufferBytes)
      )
    }
    guard readBytes >= stride else { return nil }

    var paths: [String] = []
    for descriptor in descriptors.prefix(Int(readBytes) / stride)
    where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let infoSize = MemoryLayout<vnode_fdinfowithpath>.stride
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidfdinfo(
          processID,
          descriptor.proc_fd,
          PROC_PIDFDVNODEPATHINFO,
          pointer,
          Int32(infoSize)
        )
      }
      guard result == infoSize else { continue }

      let path = withUnsafePointer(to: info.pvip.vip_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
          String(cString: $0)
        }
      }
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  private func processTable() -> [kinfo_proc]? {
    var managementInformationBase = [Int32(CTL_KERN), KERN_PROC, KERN_PROC_ALL, 0]
    var requiredSize = 0
    guard
      sysctl(
        &managementInformationBase,
        u_int(managementInformationBase.count),
        nil,
        &requiredSize,
        nil,
        0
      ) == 0
    else { return nil }

    let stride = MemoryLayout<kinfo_proc>.stride
    var capacity = max(requiredSize / stride + 16, 16)
    for _ in 0..<3 {
      var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
      var bufferSize = processes.count * stride
      let result = processes.withUnsafeMutableBytes { buffer in
        sysctl(
          &managementInformationBase,
          u_int(managementInformationBase.count),
          buffer.baseAddress,
          &bufferSize,
          nil,
          0
        )
      }
      if result == 0 {
        return Array(processes.prefix(bufferSize / stride))
      }
      guard errno == ENOMEM else { return nil }
      capacity *= 2
    }
    return nil
  }

  private func processName(_ process: kinfo_proc) -> String {
    withUnsafePointer(to: process.kp_proc.p_comm) { pointer in
      pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) {
        String(cString: $0)
      }
    }
  }
}

enum CodexLifecycleEventKind: Equatable, Sendable {
  case started
  case completed
}

struct CodexLifecycleEvent: Equatable, Sendable {
  let kind: CodexLifecycleEventKind
  let turnID: String?
  let startedAt: Date?
}

enum CodexLifecycleParseResult: Equatable, Sendable {
  case event(CodexLifecycleEvent)
  case irrelevant
  case malformedLifecycleEvent
  case oversizedRecord
}

enum CodexLifecycleParser {
  struct PositionedEvent {
    let offset: Int
    let event: CodexLifecycleEvent
  }

  struct ScanResult {
    let events: [PositionedEvent]
    let malformedOffsets: [Int]
    let oversizedOffsets: [Int]
  }

  private static let lifecycleTypes: Set<String> = [
    "task_started", "turn_started", "task_complete", "turn_complete", "turn_aborted",
  ]
  static let maximumSupportedLineBytes = 64 * 1_024

  static func parse(
    _ data: Data,
    isOverLimit: Bool = false
  ) -> CodexLifecycleParseResult {
    guard !isOverLimit, data.count <= maximumSupportedLineBytes else {
      return .oversizedRecord
    }
    let result = scan(data)
    guard result.oversizedOffsets.isEmpty else { return .oversizedRecord }
    guard result.malformedOffsets.isEmpty else { return .malformedLifecycleEvent }
    guard let event = result.events.last?.event else { return .irrelevant }
    return .event(event)
  }

  static func events(in data: Data) -> (events: [CodexLifecycleEvent], malformed: Bool) {
    let result = scan(data)
    return (
      result.events.map(\.event),
      !result.malformedOffsets.isEmpty || !result.oversizedOffsets.isEmpty
    )
  }

  static func scan(_ data: Data) -> ScanResult {
    var events: [PositionedEvent] = []
    var malformedOffsets: [Int] = []
    var oversizedOffsets: [Int] = []
    var lineStart = data.startIndex

    while lineStart < data.endIndex {
      let lineEnd = data[lineStart...].firstIndex(of: 0x0A) ?? data.endIndex
      let offset = data.distance(from: data.startIndex, to: lineStart)
      let lineLength = data.distance(from: lineStart, to: lineEnd)
      if lineLength > maximumSupportedLineBytes {
        oversizedOffsets.append(offset)
      } else {
        let line = data[lineStart..<lineEnd]
        switch parseLine(Data(line)) {
        case .event(let event):
          events.append(PositionedEvent(offset: offset, event: event))
        case .malformedLifecycleEvent:
          malformedOffsets.append(offset)
        case .oversizedRecord:
          oversizedOffsets.append(offset)
        case .irrelevant:
          break
        }
      }
      guard lineEnd < data.endIndex else { break }
      lineStart = data.index(after: lineEnd)
    }

    return ScanResult(
      events: events,
      malformedOffsets: malformedOffsets,
      oversizedOffsets: oversizedOffsets
    )
  }

  private static func parseLine(_ data: Data) -> CodexLifecycleParseResult {
    guard data.count <= maximumSupportedLineBytes else { return .oversizedRecord }
    let trimmed = data.drop(while: { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D })
    guard !trimmed.isEmpty else { return .irrelevant }

    guard
      let object = try? JSONSerialization.jsonObject(
        with: Data(trimmed),
        options: [.fragmentsAllowed]
      ) as? [String: Any]
    else {
      let containsLifecycleType = lifecycleTypes.contains { data.contains(Data($0.utf8)) }
      return containsLifecycleType ? .malformedLifecycleEvent : .irrelevant
    }

    let envelopeType = object["type"] as? String
    let payload = object["payload"] as? [String: Any]
    let lifecycleType = payload?["type"] as? String

    guard let lifecycleType, lifecycleTypes.contains(lifecycleType) else {
      return .irrelevant
    }
    guard envelopeType == "event_msg", let payload else {
      return .malformedLifecycleEvent
    }

    let kind: CodexLifecycleEventKind =
      lifecycleType == "task_started" || lifecycleType == "turn_started"
      ? .started
      : .completed
    let turnID = payload["turn_id"] as? String
    guard kind == .completed || turnID != nil else {
      return .malformedLifecycleEvent
    }

    let startedAt: Date?
    if let number = payload["started_at"] as? NSNumber {
      startedAt = Date(timeIntervalSince1970: number.doubleValue)
    } else if let string = payload["started_at"] as? String,
      let seconds = TimeInterval(string)
    {
      startedAt = Date(timeIntervalSince1970: seconds)
    } else {
      startedAt = nil
    }

    return .event(
      CodexLifecycleEvent(kind: kind, turnID: turnID, startedAt: startedAt)
    )
  }
}

final class CodexSessionActivityMonitor: CodexActivityProviding {
  private enum SessionKind {
    case root
    case child
    case unknown
  }

  private struct BootstrapLifecycleState {
    let currentTurnID: String?
    let currentTurnStartedAt: Date?
    let hasObservedSupportedLifecycle: Bool
    let hasOverLimitRecord: Bool
  }

  private struct FileState {
    let identity: UInt64
    var processedOffset: UInt64
    var pendingLinePrefix: Data
    var pendingLineIsOverLimit: Bool
    var ownerStartedAt: Date
    var currentTurnID: String?
    var currentTurnStartedAt: Date?
    var hasObservedSupportedLifecycle: Bool
    var hasOverLimitRecord: Bool
    var hasPendingBacklog: Bool
    var lastGrowthAt: Date

    var isActive: Bool { currentTurnID != nil }

    func isStalled(now: Date) -> Bool {
      isActive && now.timeIntervalSince(lastGrowthAt) >= Self.activeTurnLivenessWindow
    }

    private static let activeTurnLivenessWindow: TimeInterval = 60 * 60
  }

  private struct FailureLiveness {
    var size: UInt64
    var changedAt: Date
  }

  private static let reverseScanChunkSize = 64 * 1_024
  // A backward chunk may end in any supported JSONL record. Retain the full
  // advertised line budget plus its newline when reconstructing the next chunk.
  private static let reverseScanOverlap = CodexLifecycleParser.maximumSupportedLineBytes + 1
  private static let maximumReverseScanBytes = 64 * 1_024 * 1_024
  private static let maximumUpdateBytes = 512 * 1_024
  private static let maximumLinePrefixBytes = CodexLifecycleParser.maximumSupportedLineBytes
  private static let sessionPrefixSize = 16 * 1_024
  private static let processStartTolerance: TimeInterval = 5
  private static let failedFileLivenessWindow: TimeInterval = 15 * 60
  private static let emptyRuntimeLivenessWindow: TimeInterval = 15 * 60
  private static let uncertaintyLivenessWindow: TimeInterval = 15 * 60

  private let locator: CodexOpenSessionLocating
  private let fileManager: FileManager
  private let now: () -> Date
  private var states: [String: FileState] = [:]
  private var failureLiveness: [String: FailureLiveness] = [:]
  private var emptyInventorySince: Date?
  private var uncertaintySince: Date?
  private var lastKnownRuntime = false
  private var hasObservedSession = false

  private(set) var snapshot: CodexActivitySnapshot = .idle
  private(set) var metrics = CodexMonitorMetrics()

  var hasPendingWork: Bool {
    states.values.contains { $0.hasPendingBacklog }
  }

  var isEventSourceHealthy: Bool {
    (locator as? any CodexOpenSessionEventSource)?.isEventSourceHealthy ?? true
  }

  convenience init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    let root = homeDirectory.appending(path: ".codex/sessions")
    self.init(
      locator: LibprocCodexOpenSessionLocator(sessionRoot: root),
      fileManager: fileManager,
      now: Date.init
    )
  }

  init(
    locator: CodexOpenSessionLocating,
    fileManager: FileManager = .default,
    now: @escaping () -> Date = Date.init
  ) {
    self.locator = locator
    self.fileManager = fileManager
    self.now = now
  }

  func reset() {
    states.removeAll()
    failureLiveness.removeAll()
    emptyInventorySince = nil
    uncertaintySince = nil
    lastKnownRuntime = false
    hasObservedSession = false
    snapshot = .idle
    metrics.trackedStateCount = 0
  }

  func requestPendingWorkContinuation() {
    (locator as? any CodexKnownFileContinuationRequesting)?.requestKnownFileContinuation()
  }

  func startMonitoring(onChange: @escaping @Sendable () -> Void) {
    (locator as? CodexOpenSessionEventSource)?.startMonitoring(onChange: onChange)
  }

  func stopMonitoring() {
    (locator as? CodexOpenSessionEventSource)?.stopMonitoring()
  }

  @discardableResult
  func refresh() -> CodexActivitySnapshot {
    metrics.refreshes += 1
    let inventory: CodexOpenSessionInventory
    do {
      inventory = try locator.locateOpenSessions()
    } catch {
      metrics.trackedStateCount = states.count
      let currentTime = now()
      let since = uncertaintySince ?? currentTime
      uncertaintySince = since
      let isWithinRecoveryWindow =
        currentTime.timeIntervalSince(since) < Self.uncertaintyLivenessWindow
      let hasPositiveEvidence = snapshot.effectiveActiveCount > 0 || lastKnownRuntime
      snapshot = .unavailable(
        protectConservatively: isWithinRecoveryWindow && hasPositiveEvidence
      )
      return snapshot
    }

    lastKnownRuntime = inventory.hasCodexRuntime
    guard inventory.hasCodexRuntime else {
      states.removeAll()
      failureLiveness.removeAll()
      emptyInventorySince = nil
      uncertaintySince = nil
      hasObservedSession = false
      snapshot = .idle
      metrics.trackedStateCount = 0
      return snapshot
    }

    guard !inventory.files.isEmpty else {
      states.removeAll()
      failureLiveness.removeAll()
      metrics.trackedStateCount = 0
      guard inventory.isReliable else {
        emptyInventorySince = nil
        let currentTime = now()
        let since = uncertaintySince ?? currentTime
        uncertaintySince = since
        snapshot = .unavailable(
          protectConservatively:
            currentTime.timeIntervalSince(since) < Self.uncertaintyLivenessWindow
        )
        return snapshot
      }

      uncertaintySince = nil

      // Once a session has been observed, a reliable empty inventory means
      // that its Codex task has ended even if the Codex process remains alive.
      // Do not keep closed-lid protection active for the fallback window in
      // that normal idle state. The fallback is still retained on startup,
      // before any session has been observed, when an active task may not have
      // published its session file yet.
      guard !hasObservedSession else {
        emptyInventorySince = nil
        snapshot = .idle
        return snapshot
      }

      let currentTime = now()
      let emptySince = emptyInventorySince ?? currentTime
      emptyInventorySince = emptySince
      let isStillLive =
        currentTime.timeIntervalSince(emptySince) < Self.emptyRuntimeLivenessWindow
      snapshot =
        isStillLive
        ? .unavailable(protectConservatively: true)
        : .idle
      return snapshot
    }

    emptyInventorySince = nil
    hasObservedSession = true

    let openPaths = Set(inventory.files.map { $0.url.standardizedFileURL.path })
    states = states.filter { openPaths.contains($0.key) }
    failureLiveness = failureLiveness.filter { openPaths.contains($0.key) }

    let currentTime = now()
    var hasLiveFileFailure = false
    var hasPositiveActivityEvidence = false
    for openFile in inventory.files {
      let path = openFile.url.standardizedFileURL.path
      do {
        let identity = try fileIdentity(at: openFile.url)
        if var state = states[path], state.identity == identity {
          state.ownerStartedAt = openFile.ownerStartedAt
          let previousOffset = state.processedOffset
          try update(&state, from: openFile.url)
          discardStaleTurnIfNeeded(in: &state)
          hasPositiveActivityEvidence =
            hasPositiveActivityEvidence
            || state.processedOffset > previousOffset
          states[path] = state
          failureLiveness.removeValue(forKey: path)
        } else {
          switch try sessionKind(at: openFile.url) {
          case .child:
            states.removeValue(forKey: path)
            failureLiveness.removeValue(forKey: path)
          case .root:
            var state = try bootstrap(
              url: openFile.url,
              identity: identity,
              ownerStartedAt: openFile.ownerStartedAt
            )
            discardStaleTurnIfNeeded(in: &state)
            hasPositiveActivityEvidence = hasPositiveActivityEvidence || state.isActive
            states[path] = state
            failureLiveness.removeValue(forKey: path)
          case .unknown:
            states.removeValue(forKey: path)
            hasLiveFileFailure =
              failureIsLive(
                at: openFile.url,
                currentTime: currentTime
              ) || hasLiveFileFailure
          }
        }
      } catch {
        states[path]?.hasPendingBacklog = false
        hasLiveFileFailure =
          failureIsLive(
            at: openFile.url,
            currentTime: currentTime
          ) || hasLiveFileFailure
      }
    }

    let hasLiveUnknownState = states.values.contains {
      !$0.hasObservedSupportedLifecycle
        && currentTime.timeIntervalSince($0.lastGrowthAt)
          < Self.failedFileLivenessWindow
    }
    let hasLiveOverLimitRecord = states.values.contains {
      $0.hasOverLimitRecord
        && currentTime.timeIntervalSince($0.lastGrowthAt)
          < Self.failedFileLivenessWindow
    }
    let hadFailure =
      !inventory.isReliable
      || hasLiveFileFailure
      || hasLiveUnknownState
      || hasLiveOverLimitRecord
    let activeCount = states.values.count {
      $0.isActive && !$0.isStalled(now: currentTime)
    }
    if hadFailure {
      if hasPositiveActivityEvidence {
        // Fresh lifecycle bytes or a successfully reconstructed active turn
        // are positive evidence. Re-enter the bounded recovery window, while
        // repeated failures without new evidence continue to age naturally.
        uncertaintySince = nil
      }
      let since = uncertaintySince ?? currentTime
      uncertaintySince = since
      let isWithinRecoveryWindow =
        currentTime.timeIntervalSince(since) < Self.uncertaintyLivenessWindow
      snapshot = .unavailable(
        protectConservatively: activeCount > 0 || inventory.hasCodexRuntime
          ? isWithinRecoveryWindow
          : false
      )
    } else if activeCount > 0 {
      uncertaintySince = nil
      snapshot = .active(turnCount: activeCount)
    } else {
      uncertaintySince = nil
      snapshot = .idle
    }
    metrics.trackedStateCount = states.count
    return snapshot
  }

  private func failureIsLive(at url: URL, currentTime: Date) -> Bool {
    let path = url.standardizedFileURL.path
    do {
      let attributes = try fileManager.attributesOfItem(atPath: path)
      guard let number = attributes[.size] as? NSNumber else {
        throw CocoaError(.fileReadUnknown)
      }
      let size = number.uint64Value
      if let previous = failureLiveness[path], previous.size == size {
        return currentTime.timeIntervalSince(previous.changedAt)
          < Self.failedFileLivenessWindow
      }
      failureLiveness[path] = FailureLiveness(size: size, changedAt: currentTime)
      uncertaintySince = currentTime
      return true
    } catch {
      guard fileManager.fileExists(atPath: path) else {
        failureLiveness.removeValue(forKey: path)
        return false
      }
      if let previous = failureLiveness[path] {
        // Metadata/read failures do not constitute fresh activity. Keep the
        // original timestamp so repeated failures age out naturally.
        return currentTime.timeIntervalSince(previous.changedAt)
          < Self.failedFileLivenessWindow
      }
      failureLiveness[path] = FailureLiveness(size: 0, changedAt: currentTime)
      return true
    }
  }

  private func sessionKind(at url: URL) throws -> SessionKind {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: Self.sessionPrefixSize) ?? Data()
    var lineStart = prefix.startIndex
    while lineStart < prefix.endIndex {
      let lineEnd = prefix[lineStart...].firstIndex(of: 0x0A) ?? prefix.endIndex
      let line = prefix[lineStart..<lineEnd]
      if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
        object["type"] as? String == "session_meta",
        let payload = object["payload"] as? [String: Any]
      {
        if payload["thread_source"] as? String == "subagent"
          || payload["parent_thread_id"] as? String != nil
        {
          return .child
        }
        if payload["thread_source"] as? String == "user"
          || payload["parent_thread_id"] is NSNull
        {
          return .root
        }
        return .unknown
      }
      guard lineEnd < prefix.endIndex else { break }
      lineStart = prefix.index(after: lineEnd)
    }
    return .unknown
  }

  private func bootstrap(
    url: URL,
    identity: UInt64,
    ownerStartedAt: Date
  ) throws -> FileState {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let endOffset = try handle.seekToEnd()
    let committed = try lastCommittedOffset(handle: handle, endOffset: endOffset)
    guard committed.foundNewline || endOffset == 0 else {
      return FileState(
        identity: identity,
        processedOffset: endOffset,
        pendingLinePrefix: Data(),
        pendingLineIsOverLimit: false,
        ownerStartedAt: ownerStartedAt,
        currentTurnID: nil,
        currentTurnStartedAt: nil,
        hasObservedSupportedLifecycle: false,
        hasOverLimitRecord: true,
        hasPendingBacklog: false,
        lastGrowthAt: now()
      )
    }
    let lifecycle = try bootstrapLifecycleState(
      handle: handle,
      committedOffset: committed.offset
    )

    return FileState(
      identity: identity,
      processedOffset: committed.offset,
      pendingLinePrefix: Data(),
      pendingLineIsOverLimit: false,
      ownerStartedAt: ownerStartedAt,
      currentTurnID: lifecycle.currentTurnID,
      currentTurnStartedAt: lifecycle.currentTurnStartedAt,
      hasObservedSupportedLifecycle: lifecycle.hasObservedSupportedLifecycle,
      hasOverLimitRecord: lifecycle.hasOverLimitRecord,
      hasPendingBacklog: false,
      lastGrowthAt: now()
    )
  }

  private func update(_ state: inout FileState, from url: URL) throws {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let endOffset = try handle.seekToEnd()
    if endOffset < state.processedOffset {
      state = try bootstrap(
        url: url,
        identity: state.identity,
        ownerStartedAt: state.ownerStartedAt
      )
      return
    }
    guard endOffset > state.processedOffset else { return }

    state.lastGrowthAt = now()

    try handle.seek(toOffset: state.processedOffset)
    var remaining = min(
      Int(endOffset - state.processedOffset),
      Self.maximumUpdateBytes
    )
    while remaining > 0 {
      let readCount = min(remaining, Self.reverseScanChunkSize)
      let chunk = try handle.read(upToCount: readCount) ?? Data()
      guard !chunk.isEmpty else { break }
      metrics.lifecycleChunkReads += 1
      try consume(chunk, into: &state)
      state.processedOffset += UInt64(chunk.count)
      remaining -= chunk.count
    }
    state.hasPendingBacklog = endOffset > state.processedOffset
  }

  private func consume(_ data: Data, into state: inout FileState) throws {
    var segmentStart = data.startIndex
    while segmentStart < data.endIndex,
      let newline = data[segmentStart...].firstIndex(of: 0x0A)
    {
      appendLinePrefix(data[segmentStart..<newline], to: &state)
      try finishPendingLine(in: &state)
      segmentStart = data.index(after: newline)
    }
    if segmentStart < data.endIndex {
      appendLinePrefix(data[segmentStart..<data.endIndex], to: &state)
    }
  }

  private func appendLinePrefix(
    _ data: Data.SubSequence,
    to state: inout FileState
  ) {
    let remainingCapacity = Self.maximumLinePrefixBytes - state.pendingLinePrefix.count
    if data.count > remainingCapacity {
      state.pendingLineIsOverLimit = true
    }
    guard remainingCapacity > 0 else { return }
    state.pendingLinePrefix.append(contentsOf: data.prefix(remainingCapacity))
  }

  private func finishPendingLine(in state: inout FileState) throws {
    let isOverLimit = state.pendingLineIsOverLimit
    defer {
      state.pendingLinePrefix.removeAll(keepingCapacity: true)
      state.pendingLineIsOverLimit = false
    }
    switch CodexLifecycleParser.parse(
      state.pendingLinePrefix,
      isOverLimit: isOverLimit
    ) {
    case .event(let event):
      state.hasOverLimitRecord = false
      apply(event, to: &state)
    case .irrelevant:
      break
    case .malformedLifecycleEvent:
      throw CocoaError(.fileReadCorruptFile)
    case .oversizedRecord:
      state.hasOverLimitRecord = true
    }
  }

  private func apply(_ event: CodexLifecycleEvent, to state: inout FileState) {
    switch event.kind {
    case .started:
      guard let turnID = event.turnID else { return }
      state.hasObservedSupportedLifecycle = true
      state.currentTurnID = turnID
      state.currentTurnStartedAt = event.startedAt
    case .completed:
      state.hasObservedSupportedLifecycle = true
      guard let turnID = event.turnID else {
        state.currentTurnID = nil
        state.currentTurnStartedAt = nil
        return
      }
      if turnID == state.currentTurnID {
        state.currentTurnID = nil
        state.currentTurnStartedAt = nil
      }
    }
  }

  private func discardStaleTurnIfNeeded(in state: inout FileState) {
    guard state.isActive, let startedAt = state.currentTurnStartedAt else { return }
    if startedAt.addingTimeInterval(Self.processStartTolerance) < state.ownerStartedAt {
      state.currentTurnID = nil
      state.currentTurnStartedAt = nil
    }
  }

  private func bootstrapLifecycleState(
    handle: FileHandle,
    committedOffset: UInt64
  ) throws -> BootstrapLifecycleState {
    guard committedOffset > 0 else {
      return BootstrapLifecycleState(
        currentTurnID: nil,
        currentTurnStartedAt: nil,
        hasObservedSupportedLifecycle: false,
        hasOverLimitRecord: false
      )
    }
    var cursor = committedOffset
    var suffix = Data()
    var scannedBytes = 0
    var completedTurnIDs = Set<String>()
    var observedLifecycle = false

    while cursor > 0, scannedBytes < Self.maximumReverseScanBytes {
      let remainingBudget = Self.maximumReverseScanBytes - scannedBytes
      let count = min(
        UInt64(min(Self.reverseScanChunkSize, remainingBudget)),
        cursor
      )
      let start = cursor - count
      let hasPartialLeadingLine = try hasPartialLeadingLine(handle: handle, startOffset: start)
      try handle.seek(toOffset: start)
      var chunk = try handle.read(upToCount: Int(count)) ?? Data()
      let newDataCount = chunk.count
      chunk.append(suffix)

      var lines: [CodexLifecycleParseResult] = []
      var lineStart = chunk.startIndex
      while lineStart < chunk.endIndex {
        guard let lineEnd = chunk[lineStart...].firstIndex(of: 0x0A) else {
          break
        }
        let offset = chunk.distance(from: chunk.startIndex, to: lineStart)
        if offset <= newDataCount && !(offset == 0 && hasPartialLeadingLine) {
          lines.append(CodexLifecycleParser.parse(Data(chunk[lineStart..<lineEnd])))
        }
        lineStart = chunk.index(after: lineEnd)
      }

      for result in lines.reversed() {
        switch result {
        case .oversizedRecord:
          return BootstrapLifecycleState(
            currentTurnID: nil,
            currentTurnStartedAt: nil,
            hasObservedSupportedLifecycle: observedLifecycle,
            hasOverLimitRecord: true
          )
        case .malformedLifecycleEvent:
          throw CocoaError(.fileReadCorruptFile)
        case .irrelevant:
          continue
        case .event(let event):
          observedLifecycle = true

          switch event.kind {
          case .completed:
            guard let turnID = event.turnID else {
              return BootstrapLifecycleState(
                currentTurnID: nil,
                currentTurnStartedAt: nil,
                hasObservedSupportedLifecycle: true,
                hasOverLimitRecord: false
              )
            }
            completedTurnIDs.insert(turnID)
          case .started:
            guard let turnID = event.turnID else {
              throw CocoaError(.fileReadCorruptFile)
            }
            let isCompleted = completedTurnIDs.contains(turnID)
            return BootstrapLifecycleState(
              currentTurnID: isCompleted ? nil : turnID,
              currentTurnStartedAt: isCompleted ? nil : event.startedAt,
              hasObservedSupportedLifecycle: true,
              hasOverLimitRecord: false
            )
          }
        }
      }

      suffix = Data(chunk.prefix(Self.reverseScanOverlap))
      cursor = start
      scannedBytes += newDataCount
    }

    let reachedBeginning = cursor == 0
    return BootstrapLifecycleState(
      currentTurnID: nil,
      currentTurnStartedAt: nil,
      hasObservedSupportedLifecycle: reachedBeginning && observedLifecycle,
      hasOverLimitRecord: false
    )
  }

  private struct CommittedOffset {
    let offset: UInt64
    let foundNewline: Bool
  }

  private func lastCommittedOffset(
    handle: FileHandle,
    endOffset: UInt64
  ) throws -> CommittedOffset {
    guard endOffset > 0 else {
      return CommittedOffset(offset: 0, foundNewline: false)
    }
    var cursor = endOffset
    var scannedBytes: UInt64 = 0
    while cursor > 0, scannedBytes < Self.maximumReverseScanBytes {
      let count = min(
        UInt64(Self.reverseScanChunkSize),
        min(cursor, UInt64(Self.maximumReverseScanBytes) - scannedBytes)
      )
      let start = cursor - count
      try handle.seek(toOffset: start)
      let data = try handle.read(upToCount: Int(count)) ?? Data()
      if let newline = data.lastIndex(of: 0x0A) {
        return CommittedOffset(
          offset: start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1,
          foundNewline: true
        )
      }
      cursor = start
      scannedBytes += UInt64(data.count)
    }
    return CommittedOffset(offset: endOffset, foundNewline: false)
  }

  private func hasPartialLeadingLine(handle: FileHandle, startOffset: UInt64) throws -> Bool {
    guard startOffset > 0 else { return false }
    try handle.seek(toOffset: startOffset - 1)
    let preceding = try handle.read(upToCount: 1) ?? Data()
    return preceding.first != 0x0A
  }

  private func fileIdentity(at url: URL) throws -> UInt64 {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let number = attributes[.systemFileNumber] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    return number.uint64Value
  }
}
