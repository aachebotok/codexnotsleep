public struct CodingAgentResolver: Sendable {
  public let definitions: [CodingAgentDefinition]

  public init(definitions: [CodingAgentDefinition] = CodingAgentCatalog.supported) {
    self.definitions = definitions
  }

  public func resolve(_ snapshot: CodingAgentSystemSnapshot) -> [DetectedCodingAgent] {
    definitions.compactMap { definition in
      let isApplicationInstalled = definition.bundleIdentifiers.contains {
        snapshot.installedApplicationBundleIdentifiers.contains($0)
      }
      let isCLIInstalled = definition.executableNames.contains {
        snapshot.installedExecutableNames.contains($0)
      }
      let isApplicationRunning = definition.bundleIdentifiers.contains {
        snapshot.runningApplicationBundleIdentifiers.contains($0)
      }
      let isCLIRunning = snapshot.runningProcesses.contains { process in
        guard process.hasControllingTerminal,
          !process.isExcludedHelper,
          definition.executableNames.contains(process.executableName)
        else { return false }
        return true
      }
      let isRunning = isApplicationRunning || isCLIRunning
      let isInstalled = isApplicationInstalled || isCLIInstalled || isRunning

      guard isInstalled else { return nil }
      return DetectedCodingAgent(
        definition: definition,
        isInstalled: isInstalled,
        isRunning: isRunning
      )
    }
    .sorted { lhs, rhs in
      if lhs.isRunning != rhs.isRunning {
        return lhs.isRunning && !rhs.isRunning
      }
      if lhs.definition.sortOrder != rhs.definition.sortOrder {
        return lhs.definition.sortOrder < rhs.definition.sortOrder
      }
      return lhs.id < rhs.id
    }
  }
}
