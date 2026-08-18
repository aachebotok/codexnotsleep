public struct CodingAgentSystemSnapshot: Equatable, Sendable {
  public let installedApplicationBundleIdentifiers: Set<String>
  public let installedExecutableNames: Set<String>
  public let runningApplicationBundleIdentifiers: Set<String>
  public let runningProcesses: [CodingAgentProcessObservation]

  public init(
    installedApplicationBundleIdentifiers: Set<String> = [],
    installedExecutableNames: Set<String> = [],
    runningApplicationBundleIdentifiers: Set<String> = [],
    runningProcesses: [CodingAgentProcessObservation] = []
  ) {
    self.installedApplicationBundleIdentifiers = installedApplicationBundleIdentifiers
    self.installedExecutableNames = installedExecutableNames
    self.runningApplicationBundleIdentifiers = runningApplicationBundleIdentifiers
    self.runningProcesses = runningProcesses
  }
}
