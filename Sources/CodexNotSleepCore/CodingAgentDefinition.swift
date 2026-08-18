public struct CodingAgentDefinition: Equatable, Hashable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let bundleIdentifiers: [String]
  public let executableNames: [String]
  public let requiredExecutablePathFragments: [String]
  public let requiredCodeSigningTeamIdentifiers: [String]
  public let homeInstallationMarkers: [String]
  public let excludedFirstArguments: [String]
  public let sortOrder: Int

  public init(
    id: String,
    displayName: String,
    bundleIdentifiers: [String] = [],
    executableNames: [String] = [],
    requiredExecutablePathFragments: [String] = [],
    requiredCodeSigningTeamIdentifiers: [String] = [],
    homeInstallationMarkers: [String] = [],
    excludedFirstArguments: [String] = [],
    sortOrder: Int
  ) {
    self.id = id
    self.displayName = displayName
    self.bundleIdentifiers = bundleIdentifiers
    self.executableNames = executableNames
    self.requiredExecutablePathFragments = requiredExecutablePathFragments
    self.requiredCodeSigningTeamIdentifiers = requiredCodeSigningTeamIdentifiers
    self.homeInstallationMarkers = homeInstallationMarkers
    self.excludedFirstArguments = excludedFirstArguments
    self.sortOrder = sortOrder
  }

  public func recognizesExecutable(
    named name: String,
    canonicalPaths: Set<String>,
    codeSigningTeamIdentifier: String? = nil,
    existingHomeMarkers: Set<String> = []
  ) -> Bool {
    guard executableNames.contains(name) else { return false }

    let hasIdentityRequirements =
      !requiredExecutablePathFragments.isEmpty
      || !requiredCodeSigningTeamIdentifiers.isEmpty
      || !homeInstallationMarkers.isEmpty
    guard hasIdentityRequirements else { return true }

    let pathMatches = canonicalPaths.contains { path in
      requiredExecutablePathFragments.contains { path.contains($0) }
    }
    let signatureMatches = codeSigningTeamIdentifier.map {
      requiredCodeSigningTeamIdentifiers.contains($0)
    } ?? false
    let markerMatches = !existingHomeMarkers.isDisjoint(with: homeInstallationMarkers)
    return pathMatches || signatureMatches || markerMatches
  }
}
