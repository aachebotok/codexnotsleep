public struct DetectedCodingAgent: Equatable, Identifiable, Sendable {
  public let definition: CodingAgentDefinition
  public let isInstalled: Bool
  public let isRunning: Bool

  public var id: String { definition.id }
  public var displayName: String { definition.displayName }

  public init(
    definition: CodingAgentDefinition,
    isInstalled: Bool,
    isRunning: Bool
  ) {
    self.definition = definition
    self.isInstalled = isInstalled
    self.isRunning = isRunning
  }
}
