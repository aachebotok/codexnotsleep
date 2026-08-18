import Foundation
import Testing

@testable import CodexNotSleepCore

@Suite struct SleepPolicyTests {
  let base = Date(timeIntervalSince1970: 1_700_000_000)

  @Test func lastTaskStartsFifteenSecondGraceThenReleases() {
    var policy = SleepPolicyMachine(config: .init(autoMode: true, graceSeconds: 15))
    #expect(policy.evaluate(activeCount: 1, now: base) == .protected(reason: "running_agent"))
    #expect(
      policy.evaluate(activeCount: 0, now: base) == .grace(until: base.addingTimeInterval(15)))
    #expect(policy.shouldProtect)
    #expect(
      policy.evaluate(activeCount: 0, now: base.addingTimeInterval(14))
        == .grace(until: base.addingTimeInterval(15)))
    #expect(policy.evaluate(activeCount: 0, now: base.addingTimeInterval(16)) == .idle)
    #expect(!policy.shouldProtect)
  }

  @Test func runningAgentCountProtectsWithoutLegacyActivityRecords() {
    var policy = SleepPolicyMachine(config: .init(autoMode: true, graceSeconds: 15))

    #expect(policy.evaluate(activeCount: 1, now: base) == .protected(reason: "running_agent"))
    #expect(policy.shouldProtect)
    #expect(
      policy.evaluate(activeCount: 0, now: base) == .grace(until: base.addingTimeInterval(15)))
  }
}
