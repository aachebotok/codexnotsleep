public struct CodingAgentProcessObservation: Equatable, Sendable {
  public let executableName: String
  public let hasControllingTerminal: Bool
  public let isExcludedHelper: Bool

  public init(
    executableName: String,
    hasControllingTerminal: Bool,
    isExcludedHelper: Bool = false
  ) {
    self.executableName = executableName
    self.hasControllingTerminal = hasControllingTerminal
    self.isExcludedHelper = isExcludedHelper
  }
}
