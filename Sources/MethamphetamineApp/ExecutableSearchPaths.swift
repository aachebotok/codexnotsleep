import Foundation

enum ExecutableSearchPaths {
  static func directories(
    fileManager: FileManager,
    homeDirectory: URL,
    environment: [String: String]
  ) -> [URL] {
    var paths =
      environment["PATH"]?
      .split(separator: ":")
      .map(String.init) ?? []

    if let openCodeInstallDirectory = environment["OPENCODE_INSTALL_DIR"] {
      paths.append(openCodeInstallDirectory)
    }
    if let xdgBinaryDirectory = environment["XDG_BIN_DIR"] {
      paths.append(xdgBinaryDirectory)
    }

    paths.append(contentsOf: [
      homeDirectory.appending(path: ".local/bin").path,
      homeDirectory.appending(path: "bin").path,
      homeDirectory.appending(path: ".claude/local").path,
      homeDirectory.appending(path: ".opencode/bin").path,
      homeDirectory.appending(path: ".cursor/bin").path,
      homeDirectory.appending(path: ".kimi-code/bin").path,
      homeDirectory.appending(path: ".grok/bin").path,
      homeDirectory.appending(path: ".amp/bin").path,
      homeDirectory.appending(path: ".continue/bin").path,
      homeDirectory.appending(path: ".kilocode/bin").path,
      homeDirectory.appending(path: ".kilo/bin").path,
      homeDirectory.appending(path: ".cargo/bin").path,
      homeDirectory.appending(path: ".bun/bin").path,
      homeDirectory.appending(path: ".volta/bin").path,
      homeDirectory.appending(path: ".npm-global/bin").path,
      homeDirectory.appending(path: "Library/pnpm").path,
      homeDirectory.appending(path: ".local/share/pnpm").path,
      homeDirectory.appending(path: ".asdf/shims").path,
      homeDirectory.appending(path: ".local/share/mise/shims").path,
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/opt/local/bin",
      "/usr/bin",
    ])

    paths.append(
      contentsOf: versionedBinaryDirectories(
        at: homeDirectory.appending(path: ".nvm/versions/node"),
        suffix: "bin",
        fileManager: fileManager
      ))
    paths.append(
      contentsOf: versionedBinaryDirectories(
        at: homeDirectory.appending(path: ".asdf/installs/nodejs"),
        suffix: "bin",
        fileManager: fileManager
      ))
    paths.append(
      contentsOf: versionedBinaryDirectories(
        at: homeDirectory.appending(path: ".local/share/mise/installs/node"),
        suffix: "bin",
        fileManager: fileManager
      ))
    paths.append(
      contentsOf: versionedBinaryDirectories(
        at: homeDirectory.appending(path: ".local/share/fnm/node-versions"),
        suffix: "installation/bin",
        fileManager: fileManager
      ))

    var seen = Set<String>()
    return paths.compactMap { path in
      let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
      let isNodeModulesBinaryDirectory = standardizedPath.contains("/node_modules/.bin")
      let isKnownGlobalYarnDirectory =
        standardizedPath.contains("/.config/yarn/global/node_modules/.bin")
        || standardizedPath.contains("/.yarn/global/node_modules/.bin")
      guard !standardizedPath.contains(".app/Contents/"),
        !isNodeModulesBinaryDirectory || isKnownGlobalYarnDirectory,
        seen.insert(standardizedPath).inserted
      else { return nil }
      return URL(fileURLWithPath: standardizedPath, isDirectory: true)
    }
  }

  private static func versionedBinaryDirectories(
    at root: URL,
    suffix: String,
    fileManager: FileManager
  ) -> [String] {
    guard
      let versions = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    return versions.map { $0.appending(path: suffix).path }
  }
}
