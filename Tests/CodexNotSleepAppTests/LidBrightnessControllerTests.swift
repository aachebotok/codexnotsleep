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
  func brightnessTransitionStartsAndFinishesGently() {
    #expect(LidBrightnessCurve.defaultTransitionDuration == 0.75)
    #expect(LidBrightnessCurve.smoothProgress(0) == 0)
    #expect(LidBrightnessCurve.smoothProgress(1) == 1)
    #expect(LidBrightnessCurve.smoothProgress(0.1) < 0.05)
    #expect(LidBrightnessCurve.smoothProgress(0.9) > 0.95)
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
