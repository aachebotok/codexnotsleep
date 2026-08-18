import Foundation

public struct SleepPolicyConfig: Codable, Equatable, Sendable {
  public var autoMode: Bool
  public var graceSeconds: TimeInterval

  public init(autoMode: Bool = true, graceSeconds: TimeInterval = 15) {
    self.autoMode = autoMode
    self.graceSeconds = graceSeconds
  }
}

public enum ProtectionPhase: Equatable, Sendable {
  case idle
  case protected(reason: String)
  case grace(until: Date)
}

public struct SleepPolicyMachine: Sendable {
  public private(set) var phase: ProtectionPhase = .idle
  public var config: SleepPolicyConfig

  public init(config: SleepPolicyConfig = SleepPolicyConfig()) {
    self.config = config
  }

  @discardableResult
  public mutating func evaluate(
    activeCount: Int,
    now: Date = Date()
  ) -> ProtectionPhase {
    if config.autoMode && activeCount > 0 {
      phase = .protected(reason: "running_agent")
      return phase
    }

    if case .protected = phase, config.graceSeconds > 0 {
      phase = .grace(until: now.addingTimeInterval(config.graceSeconds))
      return phase
    }
    if case .grace(let until) = phase, now < until {
      return phase
    }
    phase = .idle
    return phase
  }

  public var shouldProtect: Bool {
    switch phase {
    case .protected, .grace:
      true
    case .idle:
      false
    }
  }
}
