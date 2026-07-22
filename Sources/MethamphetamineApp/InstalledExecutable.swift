import Foundation

struct InstalledExecutable: Equatable, Sendable {
  let name: String
  let matchingPaths: Set<String>

  init(name: String, matchingPaths: Set<String>) {
    self.name = name
    self.matchingPaths = matchingPaths
  }

  init(name: String, launcherURL: URL) {
    self.name = name
    matchingPaths = [
      Self.canonicalPath(launcherURL.path),
      Self.canonicalPath(launcherURL.resolvingSymlinksInPath().path),
    ]
  }

  static func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
