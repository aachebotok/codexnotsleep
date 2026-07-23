import Darwin
import CoreServices
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

  @discardableResult
  func refresh() -> CodexActivitySnapshot

  func reset()
}

extension CodexActivityProviding {
  func reset() {}
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
      "Не удалось прочитать процессы Codex"
    }
  }
}

struct CodexSessionFileChanges {
  var paths = Set<String>()
  var requiresFullScan = false
}

protocol CodexSessionFileChangeObserving: AnyObject {
  func takeChanges() -> CodexSessionFileChanges
}

final class FSEventsCodexSessionFileChangeObserver: CodexSessionFileChangeObserving {
  private let lock = NSLock()
  private let queue = DispatchQueue(
    label: "app.methamphetamine.codex-session-events",
    qos: .utility
  )
  private var pendingChanges = CodexSessionFileChanges()
  private var stream: FSEventStreamRef?

  init(sessionRoot: URL) {
    var context = FSEventStreamContext(
      version: 0,
      info: Unmanaged.passUnretained(self).toOpaque(),
      retain: nil,
      release: nil,
      copyDescription: nil
    )
    let flags =
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents)
      | FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
    stream = FSEventStreamCreate(
      kCFAllocatorDefault,
      Self.callback,
      &context,
      [sessionRoot.path] as CFArray,
      FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
      0.1,
      flags
    )
    guard let stream else {
      pendingChanges.requiresFullScan = true
      return
    }
    FSEventStreamSetDispatchQueue(stream, queue)
    if !FSEventStreamStart(stream) {
      pendingChanges.requiresFullScan = true
    }
  }

  deinit {
    if let stream {
      FSEventStreamStop(stream)
      FSEventStreamInvalidate(stream)
      FSEventStreamRelease(stream)
    }
  }

  func takeChanges() -> CodexSessionFileChanges {
    lock.withLock {
      let changes = pendingChanges
      pendingChanges = CodexSessionFileChanges()
      return changes
    }
  }

  private func receive(
    paths: [String],
    flags: UnsafePointer<FSEventStreamEventFlags>,
    count: Int
  ) {
    lock.withLock {
      for index in 0..<count {
        let eventFlags = flags[index]
        if eventFlags
          & FSEventStreamEventFlags(
            kFSEventStreamEventFlagMustScanSubDirs
              | kFSEventStreamEventFlagUserDropped
              | kFSEventStreamEventFlagKernelDropped
              | kFSEventStreamEventFlagEventIdsWrapped
              | kFSEventStreamEventFlagRootChanged
          ) != 0
        {
          pendingChanges.requiresFullScan = true
        }
        if index < paths.count {
          pendingChanges.paths.insert(paths[index])
        }
      }
    }
  }

  private static let callback: FSEventStreamCallback = {
    _, callbackInfo, eventCount, eventPaths, eventFlags, _ in
    guard let callbackInfo else { return }
    let observer = Unmanaged<FSEventsCodexSessionFileChangeObserver>
      .fromOpaque(callbackInfo)
      .takeUnretainedValue()
    let pathArray = unsafeBitCast(eventPaths, to: NSArray.self)
    observer.receive(
      paths: pathArray as? [String] ?? [],
      flags: eventFlags,
      count: eventCount
    )
  }
}

final class LibprocCodexOpenSessionLocator: CodexOpenSessionLocating {
  private static let discoveryInterval: TimeInterval = 30
  private static let processStartTolerance: TimeInterval = 5

  private let sessionRoot: URL
  private let userID: uid_t
  private let processInspector: any CodexProcessInspecting
  private let fileManager: FileManager
  private let minimumDiscoveryInterval: TimeInterval
  private let now: () -> Date
  private let changeObserver: any CodexSessionFileChangeObserving
  private var discoveredPaths = Set<String>()
  private var discoveryWasReliable = true
  private var discoveredForRuntimeStartedAt: Date?
  private var lastDiscoveryAt = Date.distantPast

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

  func locateOpenSessions() throws -> CodexOpenSessionInventory {
    guard let codexProcesses = processInspector.currentUserCodexProcesses(userID: userID) else {
      throw CodexOpenSessionLocatorError.processInventoryUnavailable
    }
    guard !codexProcesses.isEmpty else {
      resetDiscovery()
      return CodexOpenSessionInventory(hasCodexRuntime: false, files: [], isReliable: true)
    }

    let runtimeStartedAt = codexProcesses.map(\.startedAt).min() ?? .distantPast
    applyFileChanges(runtimeStartedAt: runtimeStartedAt)
    refreshDiscoveredPathsIfNeeded(runtimeStartedAt: runtimeStartedAt)

    var ownersByPath: [String: Date] = [:]
    var readableProcessCount = 0

    for process in codexProcesses {
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

    for path in discoveredPaths {
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

    return CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: files,
      isReliable: readableProcessCount == codexProcesses.count && discoveryWasReliable
    )
  }

  private func applyFileChanges(runtimeStartedAt: Date) {
    let changes = changeObserver.takeChanges()
    if changes.requiresFullScan {
      lastDiscoveryAt = .distantPast
    }
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
          discoveredPaths.insert(url.path)
        } else {
          discoveredPaths.remove(url.path)
        }
      } catch {
        if !fileManager.fileExists(atPath: url.path) {
          discoveredPaths.remove(url.path)
        } else {
          discoveryWasReliable = false
        }
      }
    }
  }

  private func refreshDiscoveredPathsIfNeeded(runtimeStartedAt: Date) {
    let currentTime = now()
    let runtimeChanged = discoveredForRuntimeStartedAt != runtimeStartedAt
    guard
      runtimeChanged
        || currentTime.timeIntervalSince(lastDiscoveryAt) >= minimumDiscoveryInterval
    else { return }

    let cutoff = runtimeStartedAt.addingTimeInterval(-Self.processStartTolerance)
    let resourceKeys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
    var paths = Set<String>()
    var wasReliable = true
    let enumerator = fileManager.enumerator(
      at: sessionRoot,
      includingPropertiesForKeys: resourceKeys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) { _, _ in
      wasReliable = false
      return true
    }

    if let enumerator {
      for case let url as URL in enumerator {
        guard isSessionJSONL(url.path) else { continue }
        do {
          let values = try url.resourceValues(forKeys: Set(resourceKeys))
          guard
            values.isRegularFile == true,
            let modifiedAt = values.contentModificationDate,
            modifiedAt >= cutoff
          else { continue }
          paths.insert(url.standardizedFileURL.path)
        } catch {
          wasReliable = false
        }
      }
    } else if fileManager.fileExists(atPath: sessionRoot.path) {
      wasReliable = false
    }

    discoveredPaths = paths
    discoveryWasReliable = wasReliable
    discoveredForRuntimeStartedAt = runtimeStartedAt
    lastDiscoveryAt = currentTime
  }

  private func resetDiscovery() {
    discoveredPaths.removeAll()
    discoveryWasReliable = true
    discoveredForRuntimeStartedAt = nil
    lastDiscoveryAt = .distantPast
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
}

enum CodexLifecycleParser {
  private struct Marker {
    let bytes: Data
    let lifecycleToken: Data
    let kind: CodexLifecycleEventKind
  }

  struct PositionedEvent {
    let offset: Int
    let event: CodexLifecycleEvent
  }

  struct ScanResult {
    let events: [PositionedEvent]
    let malformedOffsets: [Int]
  }

  private static let taskStartedToken = Data(#""type":"task_started""#.utf8)
  private static let turnStartedToken = Data(#""type":"turn_started""#.utf8)
  private static let taskCompleteToken = Data(#""type":"task_complete""#.utf8)
  private static let turnCompleteToken = Data(#""type":"turn_complete""#.utf8)
  private static let turnAbortedToken = Data(#""type":"turn_aborted""#.utf8)

  private static let markers: [Marker] = [
    Marker(
      bytes: Data(#""type":"event_msg","payload":{"type":"task_started""#.utf8),
      lifecycleToken: taskStartedToken,
      kind: .started
    ),
    Marker(
      bytes: Data(#""type":"event_msg","payload":{"type":"turn_started""#.utf8),
      lifecycleToken: turnStartedToken,
      kind: .started
    ),
    Marker(
      bytes: Data(#""type":"event_msg","payload":{"type":"task_complete""#.utf8),
      lifecycleToken: taskCompleteToken,
      kind: .completed
    ),
    Marker(
      bytes: Data(#""type":"event_msg","payload":{"type":"turn_complete""#.utf8),
      lifecycleToken: turnCompleteToken,
      kind: .completed
    ),
    Marker(
      bytes: Data(#""type":"event_msg","payload":{"type":"turn_aborted""#.utf8),
      lifecycleToken: turnAbortedToken,
      kind: .completed
    ),
  ]

  private static let lifecycleTokens = [
    taskStartedToken,
    turnStartedToken,
    taskCompleteToken,
    turnCompleteToken,
    turnAbortedToken,
  ]

  static func parse(_ data: Data) -> CodexLifecycleParseResult {
    let result = scan(data)
    guard result.malformedOffsets.isEmpty else { return .malformedLifecycleEvent }
    guard let event = result.events.last?.event else { return .irrelevant }
    return .event(event)
  }

  static func events(in data: Data) -> (events: [CodexLifecycleEvent], malformed: Bool) {
    let result = scan(data)
    return (result.events.map(\.event), !result.malformedOffsets.isEmpty)
  }

  static func scan(_ data: Data) -> ScanResult {
    var matches: [(offset: Int, marker: Marker, range: Range<Data.Index>)] = []
    for marker in markers {
      var searchStart = data.startIndex
      while searchStart < data.endIndex,
        let range = data.range(of: marker.bytes, in: searchStart..<data.endIndex)
      {
        matches.append((data.distance(from: data.startIndex, to: range.lowerBound), marker, range))
        searchStart = range.upperBound
      }
    }
    matches.sort { $0.offset < $1.offset }

    var recognizedTokenOffsets = Set<Int>()
    var malformedOffsets: [Int] = []
    let parsedEvents = matches.compactMap { match -> PositionedEvent? in
      let tokenOffset = match.offset + match.marker.bytes.count - match.marker.lifecycleToken.count
      recognizedTokenOffsets.insert(tokenOffset)
      switch parseMatch(marker: match.marker, range: match.range, in: data) {
      case .event(let event):
        return PositionedEvent(offset: match.offset, event: event)
      case .malformedLifecycleEvent:
        malformedOffsets.append(match.offset)
        return nil
      case .irrelevant:
        return nil
      }
    }

    for token in lifecycleTokens {
      var searchStart = data.startIndex
      while searchStart < data.endIndex,
        let range = data.range(of: token, in: searchStart..<data.endIndex)
      {
        let offset = data.distance(from: data.startIndex, to: range.lowerBound)
        if !recognizedTokenOffsets.contains(offset) {
          malformedOffsets.append(offset)
        }
        searchStart = range.upperBound
      }
    }

    return ScanResult(
      events: parsedEvents,
      malformedOffsets: malformedOffsets.sorted()
    )
  }

  static func lastEvent(in data: Data) -> CodexLifecycleParseResult {
    parse(data)
  }

  private static func parseMatch(
    marker: Marker,
    range: Range<Data.Index>,
    in data: Data
  ) -> CodexLifecycleParseResult {
    let fieldWindowEnd = min(data.endIndex, range.upperBound + 1_024)
    let fieldWindow = data[range.upperBound..<fieldWindowEnd]
    let turnID = extractJSONString(named: "turn_id", from: fieldWindow)
    let startedAtSeconds = extractNumber(named: "started_at", from: fieldWindow)

    if marker.kind == .started, turnID == nil {
      return .malformedLifecycleEvent
    }
    return .event(
      CodexLifecycleEvent(
        kind: marker.kind,
        turnID: turnID,
        startedAt: startedAtSeconds.map(Date.init(timeIntervalSince1970:))
      )
    )
  }

  private static func extractJSONString(
    named name: String,
    from data: Data.SubSequence
  ) -> String? {
    let prefix = Data("\"\(name)\":\"".utf8)
    guard let prefixRange = data.range(of: prefix) else { return nil }
    let valueStart = prefixRange.upperBound
    guard let valueEnd = data[valueStart...].firstIndex(of: UInt8(ascii: "\"")) else {
      return nil
    }
    return String(data: data[valueStart..<valueEnd], encoding: .utf8)
  }

  private static func extractNumber(
    named name: String,
    from data: Data.SubSequence
  ) -> TimeInterval? {
    let prefix = Data("\"\(name)\":".utf8)
    guard let prefixRange = data.range(of: prefix) else { return nil }
    var end = prefixRange.upperBound
    while end < data.endIndex {
      let byte = data[end]
      guard (byte >= 48 && byte <= 57) || byte == 46 else { break }
      end = data.index(after: end)
    }
    guard end > prefixRange.upperBound,
      let value = String(data: data[prefixRange.upperBound..<end], encoding: .utf8)
    else { return nil }
    return TimeInterval(value)
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
  }

  private struct FileState {
    let identity: UInt64
    var processedOffset: UInt64
    var pendingLinePrefix: Data
    var ownerStartedAt: Date
    var currentTurnID: String?
    var currentTurnStartedAt: Date?
    var hasObservedSupportedLifecycle: Bool

    var isActive: Bool { currentTurnID != nil }
  }

  private static let reverseScanChunkSize = 64 * 1_024
  private static let reverseScanOverlap = 2 * 1_024
  private static let maximumReverseScanBytes = 64 * 1_024 * 1_024
  private static let maximumUpdateBytes = 512 * 1_024
  private static let maximumLinePrefixBytes = 4 * 1_024
  private static let sessionPrefixSize = 16 * 1_024
  private static let processStartTolerance: TimeInterval = 5

  private let locator: CodexOpenSessionLocating
  private let fileManager: FileManager
  private var states: [String: FileState] = [:]
  private var lastKnownRuntime = false

  private(set) var snapshot: CodexActivitySnapshot = .idle

  convenience init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
  ) {
    let root = homeDirectory.appending(path: ".codex/sessions")
    self.init(
      locator: LibprocCodexOpenSessionLocator(sessionRoot: root),
      fileManager: fileManager
    )
  }

  init(locator: CodexOpenSessionLocating, fileManager: FileManager = .default) {
    self.locator = locator
    self.fileManager = fileManager
  }

  func reset() {
    states.removeAll()
    lastKnownRuntime = false
    snapshot = .idle
  }

  @discardableResult
  func refresh() -> CodexActivitySnapshot {
    let inventory: CodexOpenSessionInventory
    do {
      inventory = try locator.locateOpenSessions()
    } catch {
      let shouldProtect = snapshot.effectiveActiveCount > 0 || lastKnownRuntime
      snapshot = .unavailable(protectConservatively: shouldProtect)
      return snapshot
    }

    lastKnownRuntime = inventory.hasCodexRuntime
    guard inventory.hasCodexRuntime else {
      states.removeAll()
      snapshot = .idle
      return snapshot
    }

    guard !inventory.files.isEmpty else {
      states.removeAll()
      snapshot = .unavailable(protectConservatively: true)
      return snapshot
    }

    let openPaths = Set(inventory.files.map { $0.url.standardizedFileURL.path })
    states = states.filter { openPaths.contains($0.key) }

    var hadFailure = !inventory.isReliable
    for openFile in inventory.files {
      let path = openFile.url.standardizedFileURL.path
      do {
        let identity = try fileIdentity(at: openFile.url)
        if var state = states[path], state.identity == identity {
          state.ownerStartedAt = openFile.ownerStartedAt
          try update(&state, from: openFile.url)
          discardStaleTurnIfNeeded(in: &state)
          states[path] = state
        } else {
          switch try sessionKind(at: openFile.url) {
          case .child:
            states.removeValue(forKey: path)
          case .root:
            var state = try bootstrap(
              url: openFile.url,
              identity: identity,
              ownerStartedAt: openFile.ownerStartedAt
            )
            discardStaleTurnIfNeeded(in: &state)
            states[path] = state
          case .unknown:
            states.removeValue(forKey: path)
            hadFailure = true
          }
        }
      } catch {
        hadFailure = true
      }
    }

    if states.isEmpty
      || states.values.contains(where: { !$0.hasObservedSupportedLifecycle })
    {
      hadFailure = true
    }

    let activeCount = states.values.count(where: \FileState.isActive)
    if hadFailure {
      snapshot = .unavailable(
        protectConservatively: activeCount > 0 || inventory.hasCodexRuntime
      )
    } else if activeCount > 0 {
      snapshot = .active(turnCount: activeCount)
    } else {
      snapshot = .idle
    }
    return snapshot
  }

  private func sessionKind(at url: URL) throws -> SessionKind {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let prefix = try handle.read(upToCount: Self.sessionPrefixSize) ?? Data()
    guard prefix.range(of: Data(#""type":"session_meta","payload":{"#.utf8)) != nil else {
      return .unknown
    }
    if prefix.range(of: Data(#""thread_source":"subagent""#.utf8)) != nil
      || prefix.range(of: Data(#""parent_thread_id":""#.utf8)) != nil
    {
      return .child
    }
    if prefix.range(of: Data(#""thread_source":"user""#.utf8)) != nil
      || prefix.range(of: Data(#""parent_thread_id":null"#.utf8)) != nil
    {
      return .root
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
    let committedOffset = try lastCommittedOffset(handle: handle, endOffset: endOffset)
    let lifecycle = try bootstrapLifecycleState(
      handle: handle,
      committedOffset: committedOffset
    )

    return FileState(
      identity: identity,
      processedOffset: committedOffset,
      pendingLinePrefix: Data(),
      ownerStartedAt: ownerStartedAt,
      currentTurnID: lifecycle.currentTurnID,
      currentTurnStartedAt: lifecycle.currentTurnStartedAt,
      hasObservedSupportedLifecycle: lifecycle.hasObservedSupportedLifecycle
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

    try handle.seek(toOffset: state.processedOffset)
    var remaining = min(
      Int(endOffset - state.processedOffset),
      Self.maximumUpdateBytes
    )
    while remaining > 0 {
      let readCount = min(remaining, Self.reverseScanChunkSize)
      let chunk = try handle.read(upToCount: readCount) ?? Data()
      guard !chunk.isEmpty else { break }
      try consume(chunk, into: &state)
      state.processedOffset += UInt64(chunk.count)
      remaining -= chunk.count
    }
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
    guard remainingCapacity > 0 else { return }
    state.pendingLinePrefix.append(contentsOf: data.prefix(remainingCapacity))
  }

  private func finishPendingLine(in state: inout FileState) throws {
    defer { state.pendingLinePrefix.removeAll(keepingCapacity: true) }
    switch CodexLifecycleParser.parse(state.pendingLinePrefix) {
    case .event(let event):
      apply(event, to: &state)
    case .irrelevant:
      break
    case .malformedLifecycleEvent:
      throw CocoaError(.fileReadCorruptFile)
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
        hasObservedSupportedLifecycle: false
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
      try handle.seek(toOffset: start)
      var chunk = try handle.read(upToCount: Int(count)) ?? Data()
      let newDataCount = chunk.count
      chunk.append(suffix)

      let scan = CodexLifecycleParser.scan(chunk)
      if scan.malformedOffsets.contains(where: { $0 < newDataCount }) {
        throw CocoaError(.fileReadCorruptFile)
      }
      for positionedEvent in scan.events.reversed()
      where positionedEvent.offset < newDataCount {
        let event = positionedEvent.event
        observedLifecycle = true

        switch event.kind {
        case .completed:
          guard let turnID = event.turnID else {
            return BootstrapLifecycleState(
              currentTurnID: nil,
              currentTurnStartedAt: nil,
              hasObservedSupportedLifecycle: true
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
            hasObservedSupportedLifecycle: true
          )
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
      hasObservedSupportedLifecycle: reachedBeginning && observedLifecycle
    )
  }

  private func lastCommittedOffset(
    handle: FileHandle,
    endOffset: UInt64
  ) throws -> UInt64 {
    guard endOffset > 0 else { return 0 }
    var cursor = endOffset
    while cursor > 0 {
      let count = min(UInt64(Self.reverseScanChunkSize), cursor)
      let start = cursor - count
      try handle.seek(toOffset: start)
      let data = try handle.read(upToCount: Int(count)) ?? Data()
      if let newline = data.lastIndex(of: 0x0A) {
        return start + UInt64(data.distance(from: data.startIndex, to: newline)) + 1
      }
      cursor = start
    }
    return 0
  }

  private func fileIdentity(at url: URL) throws -> UInt64 {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let number = attributes[.systemFileNumber] as? NSNumber else {
      throw CocoaError(.fileReadUnknown)
    }
    return number.uint64Value
  }
}
