import CodexNotSleepCore
import Foundation
import IOKit
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct LidBrightnessControllerTests {
  @Test
  func lidSensorStateMachineKeepsManagerReadyAfterDeviceRemoval() {
    var machine = LidSensorConnectionStateMachine()
    machine.managerOpened()
    machine.deviceAttached()
    machine.deviceDetached()
    #expect(machine.state == .managerReady)
    machine.deviceAttached()
    machine.stopped()
    #expect(machine.state == .stopped)
  }

  @Test
  func lidHIDManagerUsesRequiredStartOrderAndDoesNotActivateTwice() {
    let factory = TestLidHIDManagerFactory()
    let sensor = IOKitLidAngleSensor(managerFactory: factory)

    sensor.startMonitoring { _ in }
    sensor.startMonitoring { _ in }

    #expect(factory.managers.count == 1)
    #expect(
      factory.managers[0].events == [
        "create",
        "match",
        "input-callback",
        "matching-callback",
        "removal-callback",
        "queue",
        "cancel-handler",
        "open",
        "activate",
      ]
    )
  }

  @Test
  func lidHIDStopInvalidatesDeliveryAndCleansUpAfterCancellation() {
    let factory = TestLidHIDManagerFactory()
    let sensor = IOKitLidAngleSensor(managerFactory: factory)
    var received: [Double] = []

    sensor.startMonitoring { received.append($0) }
    let manager = factory.managers[0]
    manager.emit(rawAngle: 100)
    sensor.stopMonitoring()

    manager.emit(rawAngle: 30)
    #expect(received == [100])
    #expect(manager.cancelCount == 1)
    #expect(manager.closeCount == 0)

    manager.completeCancellation()
    manager.completeCancellation()
    #expect(manager.closeCount == 1)
  }

  @Test
  func lidHIDStopThenStartUsesFreshActivatedManagerAndRejectsStaleEvents() {
    let factory = TestLidHIDManagerFactory()
    let sensor = IOKitLidAngleSensor(managerFactory: factory)
    var received: [Double] = []

    sensor.startMonitoring { received.append($0) }
    let firstManager = factory.managers[0]
    firstManager.emit(rawAngle: 100)
    sensor.stopMonitoring()

    sensor.startMonitoring { received.append($0) }
    let secondManager = factory.managers[1]
    firstManager.emit(rawAngle: 60)
    secondManager.emit(rawAngle: 30)

    #expect(factory.managers.count == 2)
    #expect(firstManager.cancelCount == 1)
    #expect(firstManager.closeCount == 0)
    #expect(secondManager.events.contains("activate"))
    #expect(received == [100, 30])

    firstManager.completeCancellation()
    #expect(firstManager.closeCount == 1)
  }

  @Test
  func lidHIDCallbackFiltersElementAndDeliversCurrentAngleSequence() {
    let factory = TestLidHIDManagerFactory()
    let sensor = IOKitLidAngleSensor(managerFactory: factory)
    var received: [Double] = []

    sensor.startMonitoring { received.append($0) }
    let manager = factory.managers[0]
    manager.emit(
      usagePage: UInt32(IOKitLidAngleSensor.usagePage),
      usage: UInt32(IOKitLidAngleSensor.angleUsage - 1),
      rawAngle: 60
    )
    for angle in [100, 60, 30, 10, 100] {
      manager.emit(rawAngle: Int64(angle))
    }

    #expect(received == [100, 60, 30, 10, 100])
  }

  @Test
  func lidHIDOpenFailureIsClosedOnceWithoutRetrying() {
    let factory = TestLidHIDManagerFactory()
    factory.openSucceeds = false
    let sensor = IOKitLidAngleSensor(managerFactory: factory)

    sensor.startMonitoring { _ in }
    _ = sensor.currentAngle()
    _ = sensor.currentAngle()

    #expect(factory.managers.count == 1)
    #expect(factory.managers[0].cancelCount == 0)
    #expect(factory.managers[0].closeCount == 1)
  }

  @Test
  func lidHIDActivationFailureIsClosedOnceWithoutRetrying() {
    let factory = TestLidHIDManagerFactory()
    factory.activationSucceeds = false
    let sensor = IOKitLidAngleSensor(managerFactory: factory)

    sensor.startMonitoring { _ in }
    _ = sensor.currentAngle()
    _ = sensor.currentAngle()

    #expect(factory.managers.count == 1)
    #expect(factory.managers[0].cancelCount == 0)
    #expect(factory.managers[0].closeCount == 1)
  }

  @Test
  func lidHIDManagerCreationFailureDegradesWithoutRetryLoop() {
    let factory = TestLidHIDManagerFactory()
    factory.returnsNil = true
    let sensor = IOKitLidAngleSensor(managerFactory: factory)

    sensor.startMonitoring { _ in }
    _ = sensor.currentAngle()
    _ = sensor.currentAngle()

    #expect(factory.makeManagerCount == 1)
    #expect(factory.managers.isEmpty)
  }

  @Test
  func lidHIDFailureDoesNotBlockIndependentSleepProtection() {
    let suiteName = "CodexNotSleep.LidHIDFailureTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let factory = TestLidHIDManagerFactory()
    factory.openSucceeds = false
    let sensor = IOKitLidAngleSensor(managerFactory: factory)
    let brightness = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: TestDisplayBrightnessProvider(brightness: 0.8),
      schedulesTimer: false
    )
    let backend = LidBrightnessTestBackend()
    let controller = AppController(
      defaults: defaults,
      backend: backend,
      codexActivityProvider: LidBrightnessTestActivity(
        snapshot: .active(turnCount: 1)
      ),
      protectionGraceSeconds: 0,
      startsAutomatically: false,
      lidBrightnessController: brightness
    )

    controller.refreshCodexActivity()

    #expect(backend.isHeld)
    #expect(factory.makeManagerCount == 1)
  }

  @Test
  func brightnessCurveUsesOnePercentAtClosedAndOriginalAtFortyFiveDegrees() {
    let original = 0.72

    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 1) == 0.01)
    #expect(
      abs(
        LidBrightnessCurve.targetBrightness(original: original, angle: 23)
          - 0.365
      ) < 0.001
    )
    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 45) == original)
    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 180) == original)
    #expect(
      LidBrightnessCurve.targetBrightness(
        original: original,
        angle: 100,
        openAngle: 100
      ) == original
    )
    #expect(LidBrightnessCurve.targetBrightness(original: 0.3, angle: 180) == 0.3)
    #expect(LidBrightnessCurve.targetKeyboardBrightness(original: 0.8, angle: 1) == 0)
    #expect(
      abs(
        LidBrightnessCurve.targetKeyboardBrightness(original: 0.8, angle: 23)
          - 0.4
      ) < 0.001
    )
    #expect(LidBrightnessCurve.targetKeyboardBrightness(original: 0.8, angle: 45) == 0.8)
  }

  @Test
  func keyboardBacklightFollowsLidAngleAndRestoresAtFortyFiveDegrees() {
    let sensor = TestLidAngleSensor(angle: 90)
    let display = TestDisplayBrightnessProvider(brightness: 0.72)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.8)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    #expect(keyboard.writes.isEmpty)

    let start = Date()
    sensor.angle = 23
    controller.refreshBrightness(at: start)
    for frame in 1...10 {
      controller.refreshBrightness(
        at: start.addingTimeInterval(
          LidBrightnessController.transitionDuration * Double(frame) / 10
        )
      )
    }
    #expect(keyboard.writes.count == 10)
    #expect(zip(keyboard.writes, keyboard.writes.dropFirst()).allSatisfy(>))
    #expect(abs((keyboard.writes.last ?? -1) - 0.4) < 0.001)

    sensor.angle = 1
    controller.refreshBrightness(at: start.addingTimeInterval(1))
    controller.refreshBrightness(
      at: start.addingTimeInterval(1 + LidBrightnessController.transitionDuration)
    )
    #expect(abs(keyboard.writes.last ?? 1) < 0.0005)

    sensor.angle = 45
    controller.refreshBrightness(at: start.addingTimeInterval(2))
    #expect(keyboard.writes.last == 0.8)

    let writeCountAtFortyFive = keyboard.writes.count
    sensor.angle = 120
    controller.refreshBrightness(at: start.addingTimeInterval(3))
    #expect(keyboard.writes.count == writeCountAtFortyFive)
  }

  @Test
  func controllerFollowsTheLidAngleBelowFortyFiveAndDoesNothingAboveIt() {
    let sensor = TestLidAngleSensor(angle: 90)
    let display = TestDisplayBrightnessProvider(brightness: 0.72)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    #expect(display.writes.isEmpty)

    let start = Date()
    display.simulateUserBrightnessChange(to: 0.6)
    sensor.angle = 34
    controller.refreshBrightness(at: start)
    let expectedAt34 = LidBrightnessCurve.targetBrightness(original: 0.6, angle: 34)
    for frame in 1...9 {
      controller.refreshBrightness(
        at: start.addingTimeInterval(
          LidBrightnessController.transitionDuration * Double(frame) / 10
        )
      )
    }
    let intermediateWrites = display.writes.map(\.brightness)
    #expect(intermediateWrites.count == 9)
    #expect(zip(intermediateWrites, intermediateWrites.dropFirst()).allSatisfy(>))
    #expect((intermediateWrites.last ?? 0) > expectedAt34)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(abs((display.writes.last?.brightness ?? -1) - expectedAt34) < 0.001)

    let secondStart = start.addingTimeInterval(1)
    sensor.angle = 20
    controller.refreshBrightness(at: secondStart)
    let expectedAt20 = LidBrightnessCurve.targetBrightness(original: 0.6, angle: 20)
    controller.refreshBrightness(
      at: secondStart.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(abs((display.writes.last?.brightness ?? -1) - expectedAt20) < 0.001)
    #expect(expectedAt20 < expectedAt34)

    sensor.angle = 45
    controller.refreshBrightness(at: secondStart.addingTimeInterval(1))
    #expect(display.writes.last?.brightness == 0.6)

    let writeCountAtFortyFive = display.writes.count
    sensor.angle = 120
    controller.refreshBrightness(at: secondStart.addingTimeInterval(2))
    #expect(display.writes.count == writeCountAtFortyFive)
  }

  @Test
  func transientSensorFailureDoesNotDisableAngleTracking() {
    let sensor = TestLidAngleSensor(angle: nil)
    let display = TestDisplayBrightnessProvider(brightness: 0.65)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    #expect(display.writes.isEmpty)

    let start = Date()
    sensor.angle = 30
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(display.writes.count == 1)
    #expect(
      abs(
        (display.writes.last?.brightness ?? -1)
          - LidBrightnessCurve.targetBrightness(original: 0.65, angle: 30)
      ) < 0.001
    )

    sensor.angle = nil
    controller.refreshBrightness(at: start.addingTimeInterval(1))
    sensor.angle = 45
    controller.refreshBrightness(at: start.addingTimeInterval(2))
    #expect(display.writes.last?.brightness == 0.65)
  }

  @Test
  func stoppingWorkRestoresOriginalBrightness() {
    let sensor = TestLidAngleSensor(angle: 90)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    sensor.angle = 25
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect((display.writes.last?.brightness ?? 1) < 0.8)

    controller.setCodexWorking(false)
    #expect(display.writes.last?.brightness == 0.8)
  }

  @Test
  func interpolationTimerExistsOnlyDuringARealTransition() {
    let sensor = TestLidAngleSensor(angle: 90)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: true
    )

    controller.setCodexWorking(true)
    #expect(!controller.isInterpolationTimerActive)

    let start = Date()
    sensor.angle = 25
    controller.refreshBrightness(at: start)
    #expect(controller.isInterpolationTimerActive)

    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(!controller.isInterpolationTimerActive)
  }

  @Test
  func brightnessProviderFailureDisablesOnlyBrightnessAndRestoresState() {
    let sensor = TestLidAngleSensor(angle: 90)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    sensor.angle = 25
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(at: start.addingTimeInterval(0.05))
    display.failNextWrite = true
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )

    #expect(display.writes.last?.brightness == 0.8)
    sensor.angle = 20
    controller.refreshBrightness(at: start.addingTimeInterval(1))
    #expect(display.writes.last?.brightness == 0.8)
  }

  @Test
  func failedRestoreRetainsOwnershipForLaterLifecycleRetry() {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect((display.writes.last?.brightness ?? 1) < 0.8)

    display.failNextWrite = true
    controller.setCodexWorking(false)
    #expect(display.writes.last?.brightness != 0.8)

    controller.setCodexWorking(true)
    controller.setCodexWorking(false)
    #expect(display.writes.last?.brightness == 0.8)
  }

  @Test
  func displayRestoresEvenWhenKeyboardRestoreIsTemporarilyUnavailable() {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.7)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    keyboard.failNextWrite = true
    controller.setCodexWorking(false)

    #expect(display.brightness == 0.8)
    #expect(keyboard.brightness != 0.7)
    #expect(controller.isRestoreRetryScheduled)
  }

  @Test
  func brightnessRestoreRetryBudgetIsFinite() async throws {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.7)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    keyboard.failAllWrites = true
    controller.setCodexWorking(false)
    try await Task.sleep(for: .seconds(1.1))

    #expect(!controller.isRestoreRetryScheduled)
    #expect(keyboard.brightness != 0.7)
  }

  @Test
  func shutdownRestoreCompletesAfterImmediateSuccessAndCancelsResources() async {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.7)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: true
    )
    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )

    let result = await shutdownRestore(controller)

    #expect(result == .restored)
    #expect(display.brightness == 0.8)
    #expect(keyboard.brightness == 0.7)
    #expect(!controller.isInterpolationTimerActive)
    #expect(!controller.isRestoreRetryScheduled)
  }

  @Test
  func shutdownRestoreKeepsDisplayIndependentFromDelayedKeyboardRecovery() async {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.7)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: false
    )
    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    keyboard.failNextWrite = true

    let result = await shutdownRestore(controller)

    #expect(result == .restored)
    #expect(display.brightness == 0.8)
    #expect(keyboard.brightness == 0.7)
    #expect(!controller.isRestoreRetryScheduled)
  }

  @Test
  func shutdownRestoreExhaustionIsFiniteAndLeavesNoRetryTask() async {
    let sensor = TestLidAngleSensor(angle: 25)
    let display = TestDisplayBrightnessProvider(brightness: 0.8)
    let keyboard = TestKeyboardBacklightProvider(brightness: 0.7)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      keyboardProvider: keyboard,
      schedulesTimer: true
    )
    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(at: start)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    keyboard.failAllWrites = true

    let result = await shutdownRestore(controller)

    #expect(result == .exhausted)
    #expect(display.brightness == 0.8)
    #expect(keyboard.brightness != 0.7)
    #expect(!controller.isInterpolationTimerActive)
    #expect(!controller.isRestoreRetryScheduled)
  }

  @Test
  func externalTerminationUsesOneSynchronousBrightnessAttemptWithoutRetryTask() {
    let sensor = TestLidAngleSensor(angle: 1)
    let display = TestDisplayBrightnessProvider(brightness: 0.72)
    let controller = LidBrightnessController(
      angleSensor: sensor,
      displayProvider: display,
      schedulesTimer: false
    )

    controller.setCodexWorking(true)
    let start = Date()
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    display.failNextWrite = true

    let result = controller.restoreForExternalTermination()

    #expect(result == .exhausted)
    #expect(!controller.isRestoreRetryScheduled)
    #expect(!controller.isInterpolationTimerActive)
  }

  @Test
  func controllerDimsOnlyForConfirmedActiveCodexWork() {
    let suiteName = "CodexNotSleep.LidBrightnessTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let activity = LidBrightnessTestActivity(snapshot: .unavailable(protectConservatively: true))
    let brightness = RecordingLidBrightnessController()
    let controller = AppController(
      defaults: defaults,
      backend: LidBrightnessTestBackend(),
      codexActivityProvider: activity,
      protectionGraceSeconds: 0,
      startsAutomatically: false,
      lidBrightnessController: brightness
    )

    controller.refreshCodexActivity()
    #expect(brightness.events.last != true)

    activity.snapshot = .active(turnCount: 1)
    controller.refreshCodexActivity()
    #expect(brightness.events.last == true)

    activity.snapshot = .idle
    controller.refreshCodexActivity()
    #expect(brightness.events.last == false)

    controller.setProtectionEnabled(false)
    #expect(brightness.events.last == false)
  }

  private func shutdownRestore(
    _ controller: LidBrightnessController
  ) async -> BrightnessRestoreResult {
    await withCheckedContinuation { continuation in
      controller.restoreForShutdown { result in
        continuation.resume(returning: result)
      }
    }
  }
}

@MainActor
private final class TestLidHIDManagerFactory: LidHIDManagerFactory {
  var openSucceeds = true
  var activationSucceeds = true
  var returnsNil = false
  var autoCompleteCancellation = false
  private(set) var makeManagerCount = 0
  private(set) var managers: [TestLidHIDManagerAdapter] = []

  func makeManager() -> (any LidHIDManagerAdapter)? {
    makeManagerCount += 1
    guard !returnsNil else { return nil }
    let manager = TestLidHIDManagerAdapter(
      openSucceeds: openSucceeds,
      activationSucceeds: activationSucceeds,
      autoCompleteCancellation: autoCompleteCancellation
    )
    managers.append(manager)
    return manager
  }
}

@MainActor
private final class TestLidHIDManagerAdapter: LidHIDManagerAdapter {
  private let openSucceeds: Bool
  private let activationSucceeds: Bool
  private let autoCompleteCancellation: Bool
  private var inputValueHandler: LidHIDInputHandler?
  private var cancellationHandler: LidHIDEventHandler?
  private var didClose = false

  private(set) var events = ["create"]
  private(set) var cancelCount = 0
  private(set) var closeCount = 0

  init(
    openSucceeds: Bool,
    activationSucceeds: Bool,
    autoCompleteCancellation: Bool
  ) {
    self.openSucceeds = openSucceeds
    self.activationSucceeds = activationSucceeds
    self.autoCompleteCancellation = autoCompleteCancellation
  }

  func setDeviceMatching(_ matching: [String: Any]) {
    events.append("match")
  }

  func registerInputValueHandler(_ handler: @escaping LidHIDInputHandler) {
    inputValueHandler = handler
    events.append("input-callback")
  }

  func registerDeviceMatchingHandler(_ handler: @escaping LidHIDEventHandler) {
    events.append("matching-callback")
  }

  func registerDeviceRemovalHandler(_ handler: @escaping LidHIDEventHandler) {
    events.append("removal-callback")
  }

  func setDispatchQueue(_ queue: DispatchQueue) {
    events.append("queue")
  }

  func setCancellationHandler(_ handler: @escaping LidHIDEventHandler) {
    cancellationHandler = handler
    events.append("cancel-handler")
  }

  func open() -> IOReturn {
    events.append("open")
    return openSucceeds ? kIOReturnSuccess : kIOReturnError
  }

  func activate() -> Bool {
    events.append("activate")
    return activationSucceeds
  }

  func copyDevices() -> CFSet? { nil }

  func cancel() {
    cancelCount += 1
    events.append("cancel")
    if autoCompleteCancellation {
      cancellationHandler?()
    }
  }

  func close() {
    guard !didClose else { return }
    didClose = true
    closeCount += 1
    events.append("close")
  }

  func emit(
    usagePage: UInt32 = UInt32(IOKitLidAngleSensor.usagePage),
    usage: UInt32 = UInt32(IOKitLidAngleSensor.angleUsage),
    rawAngle: Int64
  ) {
    inputValueHandler?(
      LidHIDInputValue(
        usagePage: usagePage,
        usage: usage,
        integerValue: rawAngle
      )
    )
  }

  func completeCancellation() {
    cancellationHandler?()
  }
}

@MainActor
private final class TestLidAngleSensor: LidAngleProviding {
  var angle: Double?

  init(angle: Double?) {
    self.angle = angle
  }

  func currentAngle() -> Double? { angle }
}

@MainActor
private final class TestDisplayBrightnessProvider: DisplayBrightnessProviding {
  struct Write {
    let brightness: Double
    let displayID: UInt32
  }

  let displayID: UInt32 = 42
  private(set) var brightness: Double
  private(set) var writes: [Write] = []
  var failNextWrite = false

  init(brightness: Double) {
    self.brightness = brightness
  }

  func currentBuiltInDisplay() -> ManagedDisplayBrightness? {
    ManagedDisplayBrightness(id: displayID, brightness: brightness)
  }

  func setBrightness(_ brightness: Double, for displayID: UInt32) -> Bool {
    if failNextWrite {
      failNextWrite = false
      return false
    }
    self.brightness = brightness
    writes.append(Write(brightness: brightness, displayID: displayID))
    return true
  }

  func simulateUserBrightnessChange(to brightness: Double) {
    self.brightness = brightness
  }
}

@MainActor
private final class TestKeyboardBacklightProvider: KeyboardBacklightProviding {
  let keyboardID: UInt64 = 95_158_272
  private(set) var brightness: Double
  private(set) var writes: [Double] = []
  var failNextWrite = false
  var failAllWrites = false

  init(brightness: Double) {
    self.brightness = brightness
  }

  func currentBuiltInKeyboard() -> ManagedKeyboardBacklight? {
    ManagedKeyboardBacklight(id: keyboardID, brightness: brightness)
  }

  func setBrightness(_ brightness: Double, for keyboardID: UInt64) -> Bool {
    if failAllWrites { return false }
    if failNextWrite {
      failNextWrite = false
      return false
    }
    self.brightness = brightness
    writes.append(brightness)
    return true
  }
}

private final class LidBrightnessTestActivity: CodexActivityProviding {
  var snapshot: CodexActivitySnapshot

  init(snapshot: CodexActivitySnapshot) {
    self.snapshot = snapshot
  }

  func refresh() -> CodexActivitySnapshot { snapshot }
}

@MainActor
private final class RecordingLidBrightnessController: LidBrightnessControlling {
  private(set) var events: [Bool] = []

  func setCodexWorking(_ isWorking: Bool) {
    events.append(isWorking)
  }

  func reset() {
    events.append(false)
  }
}

private final class LidBrightnessTestBackend: SleepProtectionBackend {
  let identifier = "lid-brightness-test"
  private(set) var isHeld = false

  func acquire() throws { isHeld = true }
  func renew() throws {}
  func release() throws { isHeld = false }
}
