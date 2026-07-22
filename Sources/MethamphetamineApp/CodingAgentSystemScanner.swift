import AppKit
import Foundation
import MethamphetamineCore

@MainActor
final class CodingAgentSystemScanner {
  private let definitions: [CodingAgentDefinition]
  private let resolver: CodingAgentResolver
  private let workspace: NSWorkspace
  private let fileManager: FileManager
  private let homeDirectory: URL
  private let environment: [String: String]
  private let processReader: BSDProcessReader
  private var cachedInstalledApplicationBundleIdentifiers = Set<String>()
  private var cachedInstalledExecutables: [InstalledExecutable] = []
  private var cachedRunningProcesses: [CodingAgentProcessObservation] = []
  private var hasInstallationCache = false

  init(
    definitions: [CodingAgentDefinition] = CodingAgentCatalog.supported,
    workspace: NSWorkspace = .shared,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.definitions = definitions
    resolver = CodingAgentResolver(definitions: definitions)
    self.workspace = workspace
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
    self.environment = environment
    processReader = BSDProcessReader()
  }

  func detectAgents(refreshInstallations: Bool = false) -> [DetectedCodingAgent] {
    if refreshInstallations || !hasInstallationCache {
      cachedInstalledApplicationBundleIdentifiers = installedApplicationBundleIdentifiers()
      cachedInstalledExecutables = installedExecutables()
      hasInstallationCache = true
    }

    if let runningProcesses = processReader.observations(
      for: definitions,
      installedExecutables: cachedInstalledExecutables
    ) {
      cachedRunningProcesses = runningProcesses
    }

    return resolver.resolve(
      CodingAgentSystemSnapshot(
        installedApplicationBundleIdentifiers: cachedInstalledApplicationBundleIdentifiers,
        installedExecutableNames: Set(cachedInstalledExecutables.map(\.name)),
        runningApplicationBundleIdentifiers: runningApplicationBundleIdentifiers(),
        runningProcesses: cachedRunningProcesses
      )
    )
  }

  private func installedApplicationBundleIdentifiers() -> Set<String> {
    let supportedIdentifiers = Set(definitions.flatMap(\.bundleIdentifiers))
    var installedIdentifiers = Set<String>()

    for identifier in supportedIdentifiers {
      let hasValidApplication =
        workspace
        .urlsForApplications(withBundleIdentifier: identifier)
        .contains(where: applicationExists)
      if hasValidApplication {
        installedIdentifiers.insert(identifier)
      }
    }

    for root in [
      URL(fileURLWithPath: "/Applications"), homeDirectory.appending(path: "Applications"),
    ] {
      guard
        let applications = try? fileManager.contentsOfDirectory(
          at: root,
          includingPropertiesForKeys: [.isDirectoryKey],
          options: [.skipsHiddenFiles]
        )
      else { continue }

      for application in applications where application.pathExtension.lowercased() == "app" {
        guard applicationExists(application),
          let identifier = Bundle(url: application)?.bundleIdentifier,
          supportedIdentifiers.contains(identifier)
        else { continue }
        installedIdentifiers.insert(identifier)
      }
    }

    return installedIdentifiers
  }

  private func runningApplicationBundleIdentifiers() -> Set<String> {
    let supportedIdentifiers = Set(definitions.flatMap(\.bundleIdentifiers))

    return Set(
      workspace.runningApplications.compactMap { application in
        guard !application.isTerminated,
          let identifier = application.bundleIdentifier,
          supportedIdentifiers.contains(identifier),
          let bundleURL = application.bundleURL,
          applicationExists(bundleURL)
        else { return nil }
        return identifier
      })
  }

  private func installedExecutables() -> [InstalledExecutable] {
    let searchDirectories = ExecutableSearchPaths.directories(
      fileManager: fileManager,
      homeDirectory: homeDirectory,
      environment: environment
    )
    let definitionsByExecutableName = Dictionary(
      grouping: definitions.flatMap { definition in
        definition.executableNames.map { ($0, definition) }
      },
      by: \.0
    )
    let executableNames = Set(definitionsByExecutableName.keys)
    var executables: [InstalledExecutable] = []

    for executableName in executableNames {
      for directory in searchDirectories {
        let candidate = directory.appending(path: executableName)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
          !isDirectory.boolValue,
          fileManager.isExecutableFile(atPath: candidate.path)
        else { continue }

        let executable = InstalledExecutable(name: executableName, launcherURL: candidate)
        let matchingDefinitions = definitionsByExecutableName[executableName, default: []].map(\.1)
        let needsSigningIdentity = matchingDefinitions.contains {
          !$0.requiredCodeSigningTeamIdentifiers.isEmpty
        }
        let codeSigningTeamIdentifier =
          needsSigningIdentity
          ? CodeSigningIdentity.teamIdentifier(at: candidate.resolvingSymlinksInPath())
          : nil
        let hasRecognizedIdentity = matchingDefinitions.contains { definition in
          let existingMarkers = Set(
            definition.homeInstallationMarkers.filter { marker in
              fileManager.fileExists(
                atPath: homeDirectory.appending(path: marker).standardizedFileURL.path)
            })
          return definition.recognizesExecutable(
            named: executableName,
            canonicalPaths: executable.matchingPaths,
            codeSigningTeamIdentifier: codeSigningTeamIdentifier,
            existingHomeMarkers: existingMarkers
          )
        }
        guard hasRecognizedIdentity else { continue }
        executables.append(executable)
      }
    }

    return executables
  }

  private func applicationExists(_ url: URL) -> Bool {
    var isDirectory: ObjCBool = false
    return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)
      && isDirectory.boolValue
  }
}
