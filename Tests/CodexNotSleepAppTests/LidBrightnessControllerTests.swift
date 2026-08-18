import Foundation
import CodexNotSleepCore
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct LidBrightnessControllerTests {
  @Test
  func brightnessCurveUsesOnePercentAtClosedAndOriginalAtSixtyDegrees() {
    let original = 0.72

    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 1) == 0.01)
    #expect(
      abs(
        LidBrightnessCurve.targetBrightness(original: original, angle: 30.5)
          - 0.365
      ) < 0.001
    )
    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 60) == original)
    #expect(LidBrightnessCurve.targetBrightness(original: original, angle: 180) == original)
    #expect(
      LidBrightnessCurve.targetBrightness(
        original: original,
        angle: 100,
        openAngle: 100
      ) == original
    )
    #expect(LidBrightnessCurve.targetBrightness(original: 0.3, angle: 180) == 0.3)
  }

  @Test
  func controllerFollowsTheLidAngleBelowSixtyAndDoesNothingAboveIt() {
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
    sensor.angle = 45
    controller.refreshBrightness(at: start)
    let expectedAt45 = LidBrightnessCurve.targetBrightness(original: 0.6, angle: 45)
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
    #expect((intermediateWrites.last ?? 0) > expectedAt45)
    controller.refreshBrightness(
      at: start.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(abs((display.writes.last?.brightness ?? -1) - expectedAt45) < 0.001)

    let secondStart = start.addingTimeInterval(1)
    sensor.angle = 20
    controller.refreshBrightness(at: secondStart)
    let expectedAt20 = LidBrightnessCurve.targetBrightness(original: 0.6, angle: 20)
    controller.refreshBrightness(
      at: secondStart.addingTimeInterval(LidBrightnessController.transitionDuration)
    )
    #expect(abs((display.writes.last?.brightness ?? -1) - expectedAt20) < 0.001)
    #expect(expectedAt20 < expectedAt45)

    sensor.angle = 60
    controller.refreshBrightness(at: secondStart.addingTimeInterval(1))
    #expect(display.writes.last?.brightness == 0.6)

    let writeCountAtSixty = display.writes.count
    sensor.angle = 120
    controller.refreshBrightness(at: secondStart.addingTimeInterval(2))
    #expect(display.writes.count == writeCountAtSixty)
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
    sensor.angle = 60
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
  func controllerDimsOnlyForConfirmedActiveCodexWork() {
    let suiteName = "CodexNotSleep.LidBrightnessTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    defaults.set(true, forKey: "agentSleepProtectionEnabled")

    let activity = LidBrightnessTestActivity(snapshot: .unavailable(protectConservatively: true))
    let brightness = RecordingLidBrightnessController()
    let fixtureHome = FileManager.default.temporaryDirectory.appending(
      path: "CodexNotSleep.LidBrightnessTests.\(UUID().uuidString)"
    )
    let controller = AppController(
      defaults: defaults,
      detector: CodingAgentSystemScanner(homeDirectory: fixtureHome, environment: [:]),
      legacyIntegrations: LegacyIntegrationMigrator(homeDirectory: fixtureHome),
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

  init(brightness: Double) {
    self.brightness = brightness
  }

  func currentBuiltInDisplay() -> ManagedDisplayBrightness? {
    ManagedDisplayBrightness(id: displayID, brightness: brightness)
  }

  func setBrightness(_ brightness: Double, for displayID: UInt32) -> Bool {
    self.brightness = brightness
    writes.append(Write(brightness: brightness, displayID: displayID))
    return true
  }

  func simulateUserBrightnessChange(to brightness: Double) {
    self.brightness = brightness
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

@MainActor
private final class LidBrightnessTestBackend: SleepProtectionBackend {
  let identifier = "lid-brightness-test"
  private(set) var isHeld = false

  func acquire() throws { isHeld = true }
  func renew() throws {}
  func release() throws { isHeld = false }
}
