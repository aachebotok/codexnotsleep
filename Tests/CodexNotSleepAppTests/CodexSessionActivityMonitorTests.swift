import Darwin
import Foundation
import Testing

@testable import CodexNotSleepApp

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
  func parsesReorderedKeysWhitespaceAndExtraFieldsSemantically() throws {
    let line = Data(
      "  \t{ \"payload\": { \"extra\": true, \"turn_id\": \"turn-3\", \"type\": \"turn_started\" }, \"type\": \"event_msg\" }  \r"
        .utf8
    )

    let event = try #require(CodexLifecycleParser.parse(line).event)
    #expect(event == CodexLifecycleEvent(kind: .started, turnID: "turn-3", startedAt: nil))
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

  @Test
  func lifecycleKeysAfterLargeUnrelatedFieldRemainSemantic() throws {
    let line = Data(
      (#"{"prefix":""#
        + String(repeating: "x", count: 8 * 1_024)
        + #"","payload":{"type":"turn_started","turn_id":"late"},"type":"event_msg"}"#)
        .utf8
    )

    let event = try #require(CodexLifecycleParser.parse(line).event)
    #expect(event.kind == .started)
    #expect(event.turnID == "late")
  }

  @Test
  func oversizedLifecycleRecordHasExplicitConservativeClassification() {
    let line = Data(repeating: 0x78, count: CodexLifecycleParser.maximumSupportedLineBytes + 1)
    #expect(CodexLifecycleParser.parse(line) == .oversizedRecord)
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

  @Test
  func stalledActiveTurnStopsHoldingProtection() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .active(turnCount: 1))

    currentTime = currentTime.addingTimeInterval(60 * 60)

    #expect(monitor.refresh() == .idle)
  }

  @Test
  func stalledTurnRevivesWhenFileGrowsAgain() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .active(turnCount: 1))
    currentTime = currentTime.addingTimeInterval(60 * 60)
    #expect(monitor.refresh() == .idle)

    try fixture.append(noise, to: file)

    #expect(monitor.refresh() == .active(turnCount: 1))
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
  func reliableRuntimeWithoutSessionsExpiresIntoIdle() {
    let locator = FakeCodexOpenSessionLocator(files: [])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60 - 1)
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(1)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func observedSessionClosingWhileCodexRemainsAliveBecomesIdle() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [],
      isReliable: true
    )
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func newRuntimeWithoutSessionUsesStartupFallbackAfterPreviousRuntimeExited() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: false,
      files: [],
      isReliable: true
    )
    #expect(monitor.refresh() == .idle)

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [],
      isReliable: true
    )
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func findingASessionMakesLaterEmptyRuntimeIdle() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60)
    #expect(monitor.refresh() == .idle)

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [owned(file)],
      isReliable: true
    )
    #expect(monitor.refresh() == .active(turnCount: 1))

    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [],
      isReliable: true
    )
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func unreliableRuntimeWithoutSessionsStaysConservative() {
    let locator = FakeCodexOpenSessionLocator(files: [])
    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [],
      isReliable: false
    )
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(60 * 60)
    #expect(monitor.refresh() == .unavailable(protectConservatively: false))
  }

  @Test
  func positiveLifecycleEvidenceReopensTheBoundedUncertaintyWindow() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("A")])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    locator.inventory = CodexOpenSessionInventory(
      hasCodexRuntime: true,
      files: [owned(file)],
      isReliable: false
    )
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(60 * 60)
    #expect(monitor.refresh() == .unavailable(protectConservatively: false))

    try fixture.append(start("B", startedAt: 10_000), to: file)
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
  func rootWithoutSupportedLifecycleExpiresIntoIdle() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [noise])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func quietMalformedSessionExpiresIntoIdle() throws {
    let fixture = try SessionFixture()
    let malformed =
      #"{"type":"event_msg","payload":{"type":"task_started","started_at":2000}}"# + "\n"
    let file = try fixture.makeRootSession(events: [malformed])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60)
    #expect(monitor.refresh() == .idle)
  }

  @Test
  func growingMalformedSessionRenewsConservativeFallback() throws {
    let fixture = try SessionFixture()
    let malformed =
      #"{"type":"event_msg","payload":{"type":"task_started","started_at":2000}}"# + "\n"
    let file = try fixture.makeRootSession(events: [malformed])
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    var currentTime = Date(timeIntervalSince1970: 10_000)
    let monitor = CodexSessionActivityMonitor(locator: locator, now: { currentTime })

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60)
    try fixture.append(malformed, to: file)
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    currentTime = currentTime.addingTimeInterval(15 * 60 - 1)
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
    #expect(monitor.hasPendingWork)
    for _ in 0..<8 where monitor.snapshot != .idle {
      _ = monitor.refresh()
    }
    #expect(monitor.snapshot == .idle)
    #expect(!monitor.hasPendingWork)
  }

  @Test
  func giantNewlineFreeTailBootstrapsAtBoundedSafeOffset() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [])
    try fixture.append(
      Data(repeating: 0x78, count: 64 * 1_024 * 1_024 + 1),
      to: file
    )
    let locator = FakeCodexOpenSessionLocator(files: [owned(file)])
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
    #expect(!monitor.hasPendingWork)
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))
  }

  @Test
  func bootstrapReconstructsLifecycleLinesAcrossReverseChunkBoundaries() throws {
    for paddingBytes in [8 * 1_024, 32 * 1_024, 64 * 1_024 - 128] {
      let fixture = try SessionFixture()
      let event = paddedStart("boundary", paddingBytes: paddingBytes)
      let metadata =
        #"{"type":"session_meta","payload":{"id":"root","thread_source":"user"}}"# + "\n"
      let prefixLength = max(
        3,
        (64 * 1_024 - event.utf8.count / 2 - metadata.utf8.count) / 3
      )
      let file = fixture.directory.appending(path: "boundary-\(paddingBytes).jsonl")
      try Data((metadata + String(repeating: "{}\n", count: prefixLength) + event).utf8)
        .write(to: file)
      let monitor = CodexSessionActivityMonitor(
        locator: FakeCodexOpenSessionLocator(files: [owned(file)])
      )

      #expect(monitor.refresh() == .active(turnCount: 1))
    }
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
      path: "CodexNotSleep.LocatorReliabilityTests.\(UUID().uuidString)"
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
  func discoversBackgroundTaskWithoutAnOpenFileDescriptor() throws {
    let fixture = try SessionFixture()
    let runtimeStartedAt = Date(timeIntervalSince1970: 3_000)
    let file = try fixture.makeRootSession(events: [start("background", startedAt: 3_100)])
    try fixture.setModificationDate(Date(timeIntervalSince1970: 3_100), for: file)
    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: runtimeStartedAt)],
      pathsByProcessID: [101: []],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 0,
      now: { Date(timeIntervalSince1970: 3_200) }
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
  }

  @Test
  func sessionFromBeforeTheCurrentRuntimeDoesNotCreateStaleActivity() throws {
    let fixture = try SessionFixture()
    let file = try fixture.makeRootSession(events: [start("stale", startedAt: 2_000)])
    try fixture.setModificationDate(Date(timeIntervalSince1970: 2_000), for: file)
    let inspector = FakeCodexProcessInspector(
      processes: [
        CodexRuntimeProcess(
          processID: 101,
          startedAt: Date(timeIntervalSince1970: 3_000)
        )
      ],
      pathsByProcessID: [101: []],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 0,
      now: { Date(timeIntervalSince1970: 3_200) }
    )

    let inventory = try locator.locateOpenSessions()
    #expect(inventory.files.isEmpty)
    #expect(inventory.isReliable)
  }

  @Test
  func fileEventAddsAResumedBackgroundSessionWithoutAnotherFullScan() throws {
    let fixture = try SessionFixture()
    let runtimeStartedAt = Date(timeIntervalSince1970: 3_000)
    let file = try fixture.makeRootSession(events: [])
    try fixture.setModificationDate(Date(timeIntervalSince1970: 2_000), for: file)
    let observer = FakeCodexSessionFileChangeObserver()
    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: runtimeStartedAt)],
      pathsByProcessID: [101: []],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 10_000,
      now: { Date(timeIntervalSince1970: 3_200) },
      changeObserver: observer
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)
    #expect(monitor.refresh() == .unavailable(protectConservatively: true))

    try fixture.append(start("resumed", startedAt: 3_100), to: file)
    try fixture.setModificationDate(Date(timeIntervalSince1970: 3_100), for: file)
    observer.changes.paths.insert(file.path)

    #expect(monitor.refresh() == .active(turnCount: 1))
  }

  @Test
  func repeatedWritesToKnownSessionAvoidProcessAndFDCorrelation() throws {
    let fixture = try SessionFixture()
    let runtimeStartedAt = Date(timeIntervalSince1970: 3_000)
    let file = try fixture.makeRootSession(events: [start("known", startedAt: 3_100)])
    let observer = FakeCodexSessionFileChangeObserver()
    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: runtimeStartedAt)],
      pathsByProcessID: [101: [file.path]],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 10_000,
      now: { Date(timeIntervalSince1970: 3_200) },
      changeObserver: observer
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    let processScans = locator.metrics.processTableScans
    let descriptorScans = locator.metrics.fileDescriptorScans

    try fixture.append(complete("known"), to: file)
    observer.changes.paths.insert(file.path)
    #expect(monitor.refresh() == .idle)
    #expect(locator.metrics.processTableScans == processScans)
    #expect(locator.metrics.fileDescriptorScans == descriptorScans)
  }

  @Test
  func knownSessionBacklogContinuationAvoidsGlobalInventoryScans() throws {
    let fixture = try SessionFixture()
    let runtimeStartedAt = Date(timeIntervalSince1970: 3_000)
    let file = try fixture.makeRootSession(events: [start("backlog", startedAt: 3_100)])
    let observer = FakeCodexSessionFileChangeObserver()
    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: runtimeStartedAt)],
      pathsByProcessID: [101: [file.path]],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 10_000,
      now: { Date(timeIntervalSince1970: 3_200) },
      changeObserver: observer
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh() == .active(turnCount: 1))
    let processScans = locator.metrics.processTableScans
    let descriptorScans = locator.metrics.fileDescriptorScans
    let append = String(repeating: "{}\n", count: 180_000) + complete("backlog")
    try fixture.append(append, to: file)
    observer.changes.paths.insert(file.path)

    #expect(monitor.refresh() == .active(turnCount: 1))
    #expect(monitor.hasPendingWork)
    #expect(locator.metrics.processTableScans == processScans)
    #expect(locator.metrics.fileDescriptorScans == descriptorScans)

    for _ in 0..<8 where monitor.hasPendingWork {
      monitor.requestPendingWorkContinuation()
      _ = monitor.refresh()
    }

    #expect(!monitor.hasPendingWork)
    #expect(monitor.snapshot == .idle)
    #expect(locator.metrics.processTableScans == processScans)
    #expect(locator.metrics.fileDescriptorScans == descriptorScans)
  }

  @Test
  func discoveredSessionCandidatesAndTrackedStateAreBounded() throws {
    let fixture = try SessionFixture()
    let runtimeStartedAt = Date(timeIntervalSince1970: 3_000)
    for index in 0..<400 {
      _ = try fixture.makeRootSession(name: "historical-\(index)", events: [])
    }
    let active = try fixture.makeRootSession(events: [start("active", startedAt: 3_100)])
    try fixture.setModificationDate(Date(timeIntervalSince1970: 9_000), for: active)
    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: runtimeStartedAt)],
      pathsByProcessID: [101: []],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 0,
      now: { Date(timeIntervalSince1970: 9_100) }
    )
    let monitor = CodexSessionActivityMonitor(locator: locator)

    #expect(monitor.refresh().effectiveActiveCount == 1)
    #expect(locator.metrics.discoveredPathCount <= 256)
    #expect(monitor.metrics.trackedStateCount <= 256)
    #expect(locator.metrics.discoveredPathCount > 0)
  }

  @Test
  func historicalDatePartitionsArePrunedBeforeEnumeration() throws {
    let fixture = try SessionFixture()
    let fileManager = FileManager.default
    let now = Date()
    let dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: now)
    let oldPartition = fixture.directory
      .appending(path: "2020", directoryHint: .isDirectory)
      .appending(path: "01", directoryHint: .isDirectory)
      .appending(path: "01", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: oldPartition, withIntermediateDirectories: true)
    for index in 0..<2_200 {
      let url = oldPartition.appending(path: "old-\(index).jsonl")
      try Data("{}\n".utf8).write(to: url)
    }

    let currentPartition = fixture.directory
      .appending(path: String(dateComponents.year!), directoryHint: .isDirectory)
      .appending(path: String(format: "%02d", dateComponents.month!), directoryHint: .isDirectory)
      .appending(path: String(format: "%02d", dateComponents.day!), directoryHint: .isDirectory)
    try fileManager.createDirectory(at: currentPartition, withIntermediateDirectories: true)
    let active = currentPartition.appending(path: "active.jsonl")
    try Data(
      (start("partition", startedAt: Int(now.timeIntervalSince1970 - 30)) + "\n").utf8
    ).write(to: active)

    let inspector = FakeCodexProcessInspector(
      processes: [CodexRuntimeProcess(processID: 101, startedAt: now.addingTimeInterval(-60))],
      pathsByProcessID: [101: []],
      unreadableProcessIDs: []
    )
    let locator = LibprocCodexOpenSessionLocator(
      sessionRoot: fixture.directory,
      userID: 501,
      processInspector: inspector,
      minimumDiscoveryInterval: 0,
      now: { now }
    )

    let inventory = try locator.locateOpenSessions()

    #expect(inventory.files.map(\.url) == [active.standardizedFileURL])
    #expect(locator.metrics.directoryEntriesVisited < 20)
    #expect(locator.metrics.discoveredPathCount == 1)
  }

  @Test
  func fileSystemObserverReportsAChangedSessionFile() async throws {
    let fixture = try SessionFixture()
    let observer = FSEventsCodexSessionFileChangeObserver(sessionRoot: fixture.directory)
    observer.start {}
    defer { observer.stop() }
    let file = try fixture.makeRootSession(events: [start("background")])
    var observedPaths = Set<String>()

    for _ in 0..<40
    where !observedPaths.contains(where: {
      URL(fileURLWithPath: $0).lastPathComponent == file.lastPathComponent
    }) {
      try await Task.sleep(for: .milliseconds(50))
      observedPaths.formUnion(observer.takeChanges().paths)
    }

    #expect(
      observedPaths.contains {
        URL(fileURLWithPath: $0).lastPathComponent == file.lastPathComponent
      }
    )
  }

  @Test
  func rootChangeRequiresRecoveryAndObserverUsesRootWatch() {
    #expect(
      FSEventsCodexSessionFileChangeObserver.requiresFullScan(
        for: FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged)
      ))
    #expect(FSEventsObserverConfiguration.current.usesNoDefer)
  }

  @Test
  func eventSourceStartFailureUsesFiniteBackoffAndReturnsHealthy() async throws {
    let fixture = try SessionFixture()
    let starts = LockedCounter()
    let callbacks = LockedCounter()
    let stops = LockedCounter()
    let observer = FSEventsCodexSessionFileChangeObserver(
      sessionRoot: fixture.directory,
      startStream: {
        let attempt = starts.increment()
        return attempt >= 3
      },
      stopStream: {
        stops.increment()
      },
      retryDelays: [0.01, 0.01, 0.01]
    )

    observer.start { callbacks.increment() }
    for _ in 0..<100 where starts.value < 3 {
      try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(20))

    #expect(starts.value >= 3)
    #expect(observer.isEventSourceHealthy)
    #expect(callbacks.value >= 1)
    #expect(observer.takeChanges().requiresFullScan)

    observer.stop()
    let startsAfterStop = starts.value
    try await Task.sleep(for: .milliseconds(40))
    #expect(starts.value == startsAfterStop)
    #expect(stops.value == 1)
  }

  @Test
  func eventSourceCanRestartAfterACompletedStop() async throws {
    let fixture = try SessionFixture()
    let starts = LockedCounter()
    let observer = FSEventsCodexSessionFileChangeObserver(
      sessionRoot: fixture.directory,
      startStream: {
        starts.increment()
        return true
      },
      retryDelays: [0.01]
    )

    observer.start {}
    try await Task.sleep(for: .milliseconds(10))
    observer.stop()
    observer.start {}
    try await Task.sleep(for: .milliseconds(10))

    #expect(starts.value == 2)
    #expect(observer.isEventSourceHealthy)
    observer.stop()
  }

  @Test
  func optInFSEventsConfigurationMeasurement() async throws {
    guard ProcessInfo.processInfo.environment["CODEX_NOT_SLEEP_MEASURE_FSEVENTS"] == "1" else {
      return
    }

    let configurations = [
      ("A", FSEventsObserverConfiguration(latency: 0.1, usesNoDefer: true)),
      ("B", FSEventsObserverConfiguration(latency: 0.25, usesNoDefer: false)),
    ]
    for (name, configuration) in configurations {
      let fixture = try SessionFixture()
      let observer = FSEventsCodexSessionFileChangeObserver(
        sessionRoot: fixture.directory,
        configuration: configuration
      )
      observer.start {}

      let file = try fixture.makeRootSession(events: [start("measure")])
      let cpuStart = processCPUSeconds()
      let creationStart = Date.now
      var creationObserved = false
      while !creationObserved, Date.now.timeIntervalSince(creationStart) < 2 {
        creationObserved = !observer.takeChanges().paths.isEmpty
        guard !creationObserved else { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let creationLatency =
        creationObserved
        ? Date.now.timeIntervalSince(creationStart)
        : nil

      let completionStart = Date.now
      try fixture.append(complete("measure"), to: file)
      var completionObserved = false
      while !completionObserved, Date.now.timeIntervalSince(completionStart) < 2 {
        completionObserved = !observer.takeChanges().paths.isEmpty
        guard !completionObserved else { break }
        try await Task.sleep(for: .milliseconds(20))
      }
      let completionLatency =
        completionObserved
        ? Date.now.timeIntervalSince(completionStart)
        : nil
      let cpuSeconds = processCPUSeconds() - cpuStart
      print(
        "FSEvents " + name
          + ": creation=\(creationLatency.map { "\($0)s" } ?? "unavailable")"
          + " completion=\(completionLatency.map { "\($0)s" } ?? "unavailable")"
          + " callbacks=\(observer.observedCallbackCount) cpu=\(cpuSeconds)s"
          + " wakeups=unavailable energy=unavailable"
      )
      observer.stop()
    }
  }

  @Test
  func optInLiveSmokeRecognizesTheCurrentCodexTask() {
    guard ProcessInfo.processInfo.environment["CODEX_NOT_SLEEP_EXPECT_ACTIVE_CODEX"] == "1" else {
      return
    }

    let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/sessions")
    var currentTime = Date.now
    let monitor = CodexSessionActivityMonitor(
      locator: LibprocCodexOpenSessionLocator(sessionRoot: root),
      now: { currentTime }
    )
    let initialSnapshot = monitor.refresh()
    #expect(initialSnapshot.effectiveActiveCount > 0)

    if initialSnapshot.usesFallback {
      currentTime = currentTime.addingTimeInterval(15 * 60)
    }
    let settledSnapshot = monitor.refresh()
    #expect(settledSnapshot.effectiveActiveCount > 0)
    #expect(!settledSnapshot.usesFallback)
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

  private func paddedStart(_ turnID: String, paddingBytes: Int) -> String {
    let fixed =
      #"{"type":"event_msg","payload":{"type":"task_started","turn_id":"__TURN__","started_at":2000,"padding":""}}"#
      .replacingOccurrences(of: "__TURN__", with: turnID)
    let marker = "\"padding\":\"\""
    let padding = max(0, paddingBytes - fixed.utf8.count + marker.utf8.count)
    return fixed.replacingOccurrences(
      of: marker,
      with: "\"padding\":\"\(String(repeating: "x", count: padding))\""
    ) + "\n"
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

private func processCPUSeconds() -> TimeInterval {
  var usage = rusage()
  guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
  return TimeInterval(usage.ru_utime.tv_sec) + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
    + TimeInterval(usage.ru_stime.tv_sec) + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
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

private final class FakeCodexSessionFileChangeObserver: CodexSessionFileChangeObserving {
  var changes = CodexSessionFileChanges()

  func takeChanges() -> CodexSessionFileChanges {
    defer { changes = CodexSessionFileChanges() }
    return changes
  }
}

private final class LockedCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var storedValue = 0

  var value: Int {
    lock.withLock { storedValue }
  }

  @discardableResult
  func increment() -> Int {
    lock.withLock {
      storedValue += 1
      return storedValue
    }
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
      path: "CodexNotSleep.CodexSessionTests.\(UUID().uuidString)"
    )
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  var directory: URL { root }

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
    try append(Data(value.utf8), to: url)
  }

  func append(_ data: Data, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: data)
  }

  func replaceRootSession(at url: URL, events: [String]) throws {
    try fileManager.removeItem(at: url)
    let meta =
      #"{"type":"session_meta","payload":{"id":"root","thread_source":"user"}}"# + "\n"
    try Data((meta + events.joined()).utf8).write(to: url)
  }

  func setModificationDate(_ date: Date, for url: URL) throws {
    try fileManager.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
  }
}
