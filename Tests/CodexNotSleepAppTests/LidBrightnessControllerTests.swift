import CodexNotSleepCore
import Foundation
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
