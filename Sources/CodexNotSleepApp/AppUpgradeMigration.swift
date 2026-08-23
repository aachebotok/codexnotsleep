import AppKit
import Foundation

enum CodexetineMigrationChoice: Equatable {
  case moveOldAppToTrash
  case later
}

@MainActor
protocol CodexetineMigrationPrompting: AnyObject {
  func choose(oldAppURL: URL, isRunning: Bool) -> CodexetineMigrationChoice
}

@MainActor
protocol CodexetineMigrationRecycling: AnyObject {
  func recycle(
    _ url: URL,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  )
}

@MainActor
final class SystemCodexetineMigrationPrompt: CodexetineMigrationPrompting {
  func choose(oldAppURL: URL, isRunning: Bool) -> CodexetineMigrationChoice {
    let alert = NSAlert()
    alert.messageText = "Older Codex Not Sleep app still installed"
    alert.informativeText =
      isRunning
      ? "An older Codex Not Sleep app is still installed and currently running. It can cause duplicate login behavior. Quit that copy first, then choose this action again."
      : "An older Codex Not Sleep app is still installed and may cause duplicate login behavior. Move it to the Trash after you confirm."
    alert.alertStyle = .warning
    alert.addButton(withTitle: "Move Old App to Trash")
    alert.addButton(withTitle: "Later")
    return alert.runModal() == .alertFirstButtonReturn
      ? .moveOldAppToTrash
      : .later
  }
}

@MainActor
final class SystemCodexetineMigrationRecycler: CodexetineMigrationRecycling {
  func recycle(
    _ url: URL,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    NSWorkspace.shared.recycle([url]) { recycledURLs, error in
      let succeeded =
        error == nil
        && (recycledURLs.keys.contains(url) || recycledURLs.values.contains(url))
      Task { @MainActor in
        completion(succeeded)
      }
    }
  }
}

/// Offers a one-time, explicit migration for the old application bundle.
/// Preferences, leases, sudoers, and login-item registration are deliberately
/// outside this controller's scope; only the confirmed old app bundle is
/// eligible for recycling.
@MainActor
final class CodexetineUpgradeMigrationController {
  static let legacyBundleURL = URL(filePath: "/Applications/Codex Not Sleep.app")
  static let legacyBundleIdentifier = "app.codexnotsleep.CodexNotSleep2"
  static let promptShownKey = "codexetine.oldCodexNotSleepMigrationPromptShown"

  private let defaults: UserDefaults
  private let currentBundleURL: URL
  private let legacyBundleURL: URL
  private let fileManager: FileManager
  private let bundleIdentifier: (URL) -> String?
  private let isRunning: @MainActor (URL, String) -> Bool
  private let prompt: any CodexetineMigrationPrompting
  private let recycler: any CodexetineMigrationRecycling

  init(
    defaults: UserDefaults = .standard,
    currentBundleURL: URL = Bundle.main.bundleURL,
    legacyBundleURL: URL = CodexetineUpgradeMigrationController.legacyBundleURL,
    fileManager: FileManager = .default,
    bundleIdentifier: @escaping (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier },
    isRunning: @escaping @MainActor (URL, String) -> Bool = CodexetineUpgradeMigrationController
      .systemIsRunning,
    prompt: any CodexetineMigrationPrompting = SystemCodexetineMigrationPrompt(),
    recycler: any CodexetineMigrationRecycling = SystemCodexetineMigrationRecycler()
  ) {
    self.defaults = defaults
    self.currentBundleURL = currentBundleURL.standardizedFileURL
    self.legacyBundleURL = legacyBundleURL.standardizedFileURL
    self.fileManager = fileManager
    self.bundleIdentifier = bundleIdentifier
    self.isRunning = isRunning
    self.prompt = prompt
    self.recycler = recycler
  }

  func checkAndOfferMigration() {
    guard Self.isInstalledCodexetineBundle(currentBundleURL) else { return }
    guard !defaults.bool(forKey: Self.promptShownKey) else { return }
    guard legacyBundleURL != currentBundleURL else { return }
    guard fileManager.fileExists(atPath: legacyBundleURL.path) else { return }
    guard bundleIdentifier(legacyBundleURL) == Self.legacyBundleIdentifier else { return }

    let oldAppIsRunning = isRunning(legacyBundleURL, Self.legacyBundleIdentifier)
    switch prompt.choose(oldAppURL: legacyBundleURL, isRunning: oldAppIsRunning) {
    case .later:
      defaults.set(true, forKey: Self.promptShownKey)
    case .moveOldAppToTrash:
      // Never recycle a bundle while its exact, validated identity is still
      // running. The alert tells the user to quit it and try again.
      guard !oldAppIsRunning else { return }
      defaults.set(true, forKey: Self.promptShownKey)
      // The application delegate strongly owns this controller. Keep the
      // in-flight operation strongly tied to the controller as well so a
      // delayed NSWorkspace completion cannot lose the failure bookkeeping.
      recycler.recycle(legacyBundleURL) { [self] succeeded in
        if !succeeded {
          // A failed recycle may be retried explicitly on a later launch.
          defaults.set(false, forKey: Self.promptShownKey)
        }
      }
    }
  }

  static func isInstalledCodexetineBundle(_ url: URL) -> Bool {
    let standardizedURL = url.standardizedFileURL
    guard standardizedURL.lastPathComponent == "Codexetine.app" else { return false }
    return standardizedURL.path == "/Applications/Codexetine.app"
      || standardizedURL.path
        == FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Applications/Codexetine.app")
        .standardizedFileURL.path
  }

  private static func systemIsRunning(_ url: URL, _ bundleIdentifier: String) -> Bool {
    NSWorkspace.shared.runningApplications.contains { application in
      application.bundleIdentifier == bundleIdentifier
        && application.bundleURL?.standardizedFileURL == url.standardizedFileURL
    }
  }
}
