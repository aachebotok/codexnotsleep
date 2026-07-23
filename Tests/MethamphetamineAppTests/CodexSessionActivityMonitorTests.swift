import Foundation
import Testing

@testable import MethamphetamineApp

@Suite
struct CodexLifecycleParserTests {
  @Test
  func parsesLifecycleWithoutKeepingTranscriptContent() throws {
    let line = Data(
      #"{"timestamp":"2026-07-23T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"turn-1","started_at":2000,"prompt":"private prompt","code":"private code"}}"#
        .utf8
    )

    let event = try #require(CodexLifecycleParser.parse(line).event)
    #expect(event.kind == .started)
    #expect(event.turnID == "turn-1")
    #expect(event.startedAt == Date(timeIntervalSince1970: 2000))

    let reflectedFields = Mirror(reflecting: event).children.compactMap(\.label)
    #expect(reflectedFields == ["kind", "turnID", "startedAt"])
  }

  @Test
  func acceptsAliasesAndAbortWithoutTurnID() throws {
    let started = try #require(
      CodexLifecycleParser.parse(
        Data(
          #"{"type":"event_msg","payload":{"type":"turn_started","turn_id":"turn-2","started_at":2001}}"#
            .utf8
        )
      ).event
    )
    let completed = try #require(
      CodexLifecycleParser.parse(
        Data(
          #"{"type":"event_msg","payload":{"type":"turn_complete","turn_id":"turn-2"}}"#.utf8
        )
      ).event
    )
    let aborted = try #require(
      CodexLifecycleParser.parse(
        Data(#"{"type":"event_msg","payload":{"type":"turn_aborted","reason":"interrupted"}}"#.utf8)
      ).event
    )

    #expect(started.kind == .started)
    #expect(completed.kind == .completed)
    #expect(aborted == CodexLifecycleEvent(kind: .completed, turnID: nil, startedAt: nil))
  }

  @Test
  func rejectsLifecycleLookingDataOutsideEventEnvelope() {
    let wrongEnvelope = Data(
      #"{"type":"response_item","payload":{"type":"task_started","turn_id":"fake"}}"#.utf8
    )
    #expect(CodexLifecycleParser.parse(wrongEnvelope) == .malformedLifecycleEvent)
    #expect(CodexLifecycleParser.parse(Data("not json".utf8)) == .irrelevant)
  }

  @Test
  func newerUnsupportedEnvelopeCannotBeHiddenByAnOlderValidEvent() {
    let data = Data(
      (#"{"type":"event_msg","payload":{"type":"task_complete","turn_id":"A"}}"#
        + "\n"
        + #"{"type":"new_event_envelope","payload":{"type":"task_started","turn_id":"B"}}"#
        + "\n").utf8
    )

    let parsed = CodexLifecycleParser.events(in: data)
    #expect(parsed.malformed)
  }
}

@Suite
struct CodexSessionActivityMonitorTests {
  private let ownerStartedAt = Date(timeIntervalSince1970: 1_000)

  @Test
  func startCompleteAndAbortDriveActivity() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))

    try fixture.append(noise, to: file)
    #expect(monitor.refresh() == .active(turnCount: 1))

    try fixture.append(complete("A"), to: file)
    #expect(monitor.refresh() == .idle)

    try fixture.append(start("B"), to: file)
    #expect(monitor.refresh() == .active(turnCount: 1))

    try fixture.append(abort("B"), to: file)
    #expect(monitor.refresh() == .idle)
  }

  @Test(arguments: ["interrupted", "replaced", "review_ended", "budget_limited"])
  func everyCodexAbortReasonCompletesTheTask(_ reason: String) throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    try fixture.append(abort("A", reason: reason), to: file)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func severalRootTasksReleaseOnlyAfterTheLastOne() throws {
    let fixture = try SessionFixture()
    let first = try fixture.makeRootSession(name: "first", events: [start("A")])
    let second = try fixture.makeRootSession(name: "second", events: [start("B")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(first), owned(second)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 2))
    try fixture.append(complete("A"), to: first)
    #expect(monitor.refresh() == .active(turnCount: 1))
    try fixture.append(complete("B"), to: second)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func copiedHistoryAndChildSessionsDoNotCreateFalseActivity() throws {
    let fixture = try SessionFixture()
    let root = try fixture.makeRootSession(events: [
      start("old-without-terminal"),
      start("current"),
      complete("current"),
    ])
    let child = try fixture.makeChildSession(events: [start("copied-parent"), start("child")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(root), owned(child)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .idle)
  }

  @Test
  func duplicateTerminalForOldTurnDoesNotStopNewTurn() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [
      start("A"), complete("A"), start("B"),
    ])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    try fixture.append(complete("A"), to: file)
    #expect(monitor.refresh() == .active(turnCount: 1))
    try fixture.append(complete("B"), to: file)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func coldStartIgnoresDelayedTerminalForSupersededTurn() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [
      start("A"), complete("A"), start("B"), complete("A"),
    ])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])

    let restartedMonitor = CodexSessionActivityMonitor(locator: locator)
    #expect(restartedMonitor.refresh() == .active(turnCount: 1))
  }

  @Test
  func partialLineWaitsForNewlineAndMultipleAppendsAreReduced() throws {
    let fixture = try SessionFixture()
    let partialStart = start("A").dropLast()
    let file = try fixture.makeRootSession(events: [String(partialStart)])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    try fixture.append("\n\(complete("A"))\(start("B"))", to: file)
    #expect(monitor.refresh() == .active(turnCount: 1))
  }

  @Test
  func replacementTruncationAndClosedRuntimeClearState() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    try fixture.replaceRootSession(at: file, events: [start("B"), complete("B")])
    #expect(monitor.refresh() == .idle)

    try fixture.replaceRootSession(at: file, events: [start("C")])
    #expect(monitor.refresh() == .active(turnCount: 1))
    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: false,
      files: [],
      isReliable: true
    )
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func staleTurnFromPreviousCodexProcessIsIgnored() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A", startedAt: 2_000)])
    let locator = FakeCodexOpenSessionLocator(
      files: [
        CodexOpenSessionFile(
          url: file,
          ownerStartedAt: Date(timeIntervalSince1970: 3_000)
        )
      ]
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .idle)
  }

  @Test
  func transientReadFailureKeepsAnActiveTaskProtected() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    locator.error = TestLocatorError.failed
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func runtimeWithoutReadableRootSessionUsesConservativeFallback() throws {
    let locator = FakeCodexOpenSessionLocator(files: [])
    let monitor = CodexSessionActivityMonitor(locator: locator)
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [],
      isReliable: false
    )
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func rootWithoutSupportedLifecycleUsesConservativeFallback() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [noise])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func largeAppendIsConsumedInBoundedChunksWithoutLosingTerminalEvent() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)
    #expect(monitor.refresh() == .active(turnCount: 1))

    let largeNoise =
      #"{"type":"response_item","payload":{"text":""#
      + String(repeating: "x", count: 2 * 1_024 * 1_024)
      + #""}}"# + "\n"
    try fixture.append(largeNoise + complete("A"), to: file)

    #expect(monitor.refresh() == .active(turnCount: 1))
    for _ in 0..<8 where monitor.snapshot != .idle {
      _ = monitor.refresh()
    }
    #expect(monitor.snapshot == .idle)
  }

  @Test
  func unsupportedNewEnvelopeUsesFallbackEvenAfterValidHistory() throws {
    let fixture = try SessionFixture()
    let unsupportedStart =
      #"{"type":"new_event_envelope","payload":{"type":"task_started","turn_id":"B"}}"#
      + "\n"
    let file = try fixture.makeRootSession(events: [
      start("A"), complete("A"), unsupportedStart,
    ])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func malformedLifecycleUsesConservativeFallback() throws {
    let fixture = try SessionFixture()
    let malformed =
      #"{"type":"event_msg","payload":{"type":"task_started","started_at":2000}}"# + "\n"
    let file = try fixture.makeRootSession(events: [malformed])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func libprocSmokeReadsOnlyCurrentUsersOpenCodexSessions() throws {
    let inventory = try LibprocCodexOpenSessionLocator().locateOpenSessions()
    #expect(
      inventory.files.allSatisfy { file in
        file.url.path.contains("/.codex/sessions/") && file.url.path.hasSuffix(".jsonl")
      })
    if inventory.hasCodexRuntime {
      #expect(inventory.isReliable)
    }
  }

  @Test
  func oneUnreadableCodexProcessMakesTheWholeInventoryUnreliable() throws {
    let sessionRoot = FileManager.default.temporaryDirectory.appending(
      path: "Methamphetamine.LocatorReliabilityTests.\(UUID().uuidString)"
    )
    let openSession = sessionRoot.appending(path: "open.jsonl")
    let inspector = FakeCodexProcessInspector(
      processes: [
        CodexRuntimeProcess(processID: 101, startedAt: ownerStartedAt),
        CodexRuntimeProcess(processID: 102, startedAt: ownerStartedAt),
      ],
      pathsByProcessID: [101: [openSession.path]],
      unreadableProcessIDs: [102]
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: sessionRoot,
      userID: 501,
      processInspector: inspector
    )

    let inventory = try locator.locateOpenSessions()
    #expect(inventory.hasCodexRuntime)
    #expect(inventory.files.map(\.url) == [openSession.standardizedFileURL])
    #expect(!inventory.isReliable)
  }

  @Test
  func optInLiveSmokeRecognizesTheCurrentCodexTask() {
    guard ProcessInfo.processInfo.environment["METHAMPHETAMINE_EXPECT_ACTIVE_CODEX"] == "1" else {
      return
    }

    let monitor = CodexSessionActivityMonitor()
    let liveSnapshot = monitor.refresh()
    #expect(liveSnapshot.effectiveActiveCount > 0)
    #expect(!liveSnapshot.usesFallback)
  }

  private func owned(_ url: URL) -> CodexOpenSessionFile {
    CodexOpenSessionFile(url: url, ownerStartedAt: ownerStartedAt)
  }

  private func start(_ turnID: String, startedAt: Int = 2_000) -> String {
    #"{"timestamp":"2026-07-23T00:00:00Z","type":"event_msg","payload":{"type":"task_started","turn_id":"__TURN__","started_at":__STARTED_AT__}}"#
      .replacingOccurrences(of: "__TURN__", with: turnID)
      .replacingOccurrences(of: "__STARTED_AT__", with: String(startedAt))
      + "\n"
  }

  private func complete(_ turnID: String) -> String {
    #"{"timestamp":"2026-07-23T00:00:01Z","type":"event_msg","payload":{"type":"task_complete","turn_id":"__TURN__","last_agent_message":"not retained"}}"#
      .replacingOccurrences(of: "__TURN__", with: turnID)
      + "\n"
  }

  private func abort(_ turnID: String, reason: String = "interrupted") -> String {
    #"{"timestamp":"2026-07-23T00:00:01Z","type":"event_msg","payload":{"type":"turn_aborted","turn_id":"__TURN__","reason":"__REASON__"}}"#
      .replacingOccurrences(of: "__TURN__", with: turnID)
      .replacingOccurrences(of: "__REASON__", with: reason)
      + "\n"
  }

  private var noise: String {
    #"{"type":"event_msg","payload":{"type":"agent_message","message":"task_complete in prose"}}"#
      + "\n"
  }
}

extension CodexLifecycleParseResult {
  fileprivate var event: CodexLifecycleEvent? {
    if case .event(let event) = self { return event }
    return nil
  }
}

private enum TestLocatorError: Error {
  case failed
}

private final class FakeCodexOpenSessionLocator: CodexOpenSessionLocating {
  var inventory: CodexOpenSessionInventory
  var error: Error?

  init(files: [CodexOpenSessionFile]) {
    inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: files,
      isReliable: true
    )
  }

  func locateOpenSessions() throws -> CodexOpenSessionInventory {
    if let error { throw error }
    return inventory
  }
}

private struct FakeCodexProcessInspector: CodexProcessInspecting {
  let processes: [CodexRuntimeProcess]
  let pathsByProcessID: [pid_t: [String]]
  let unreadableProcessIDs: Set<pid_t>

  func currentUserCodexProcesses(userID _: uid_t) -> [CodexRuntimeProcess]? {
    processes
  }

  func openFilePaths(processID: pid_t) -> [String]? {
    guard !unreadableProcessIDs.contains(processID) else { return nil }
    return pathsByProcessID[processID] ?? []
  }
}

private final class SessionFixture {
  private let fileManager = FileManager.default
  private let root: URL

  init() throws {
    root = fileManager.temporaryDirectory.appending(
      path: "Methamphetamine.CodexSessionTests.\(UUID().uuidString)"
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    try? fileManager.removeItem(at: root)
  }

  func makeRootSession(
    name: String = UUID().uuidString,
    events: [String]
  ) throws -> URL {
    let url = root.appending(path: "\(name).jsonl")
    let meta =
      #"{"type":"session_meta","payload":{"id":"root","thread_source":"user"}}"# + "\n"
    try Data((meta + events.joined()).utf8).write(to: url)
    return url
  }

  func makeChildSession(events: [String]) throws -> URL {
    let url = root.appending(path: "child-\(UUID().uuidString).jsonl")
    let meta =
      #"{"type":"session_meta","payload":{"id":"child","parent_thread_id":"root","thread_source":"subagent"}}"#
      + "\n"
    try Data((meta + events.joined()).utf8).write(to: url)
    return url
  }

  func append(_ value: String, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(value.utf8))
  }

  func replaceRootSession(at url: URL, events: [String]) throws {
    try fileManager.removeItem(at: url)
    let meta =
      #"{"type":"session_meta","payload":{"id":"root","thread_source":"user"}}"# + "\n"
    try Data((meta + events.joined()).utf8).write(to: url)
  }
}
