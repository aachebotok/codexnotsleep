import Foundation
import Testing

@testable import CodexNotSleepApp

@Suite
@MainActor
struct AppUpgradeMigrationTests {
  @Test
  func moveRequiresExplicitConfirmationAndKeepsCurrentPreferences() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let prompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let recycler = TestMigrationRecycler()
    let controller = makeController(
      defaults: defaults,
      oldApp: oldApp,
      prompt: prompt,
      recycler: recycler
    )
    defaults.set(true, forKey: ProtectionPreferenceStore.key)

    controller.checkAndOfferMigration()

    #expect(prompt.callCount == 1)
    #expect(recycler.recycledURLs == [oldApp.standardizedFileURL])
    #expect(defaults.bool(forKey: ProtectionPreferenceStore.key))
    #expect(defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))
    #expect(
      CodexetineUpgradeMigrationController.legacyBundleURL.path
        == "/Applications/Codex Not Sleep.app")
  }

  @Test
  func laterLeavesTheOldBundleUntouchedAndDoesNotRepeatEveryLaunch() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let prompt = TestMigrationPrompt(choice: .later)
    let recycler = TestMigrationRecycler()
    let controller = makeController(
      defaults: defaults,
      oldApp: oldApp,
      prompt: prompt,
      recycler: recycler
    )

    controller.checkAndOfferMigration()
    controller.checkAndOfferMigration()

    #expect(prompt.callCount == 1)
    #expect(recycler.recycledURLs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: oldApp.path))
  }

  @Test
  func runningOldBundleCannotBeRecycledUntilItIsQuit() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let prompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let recycler = TestMigrationRecycler()
    let controller = makeController(
      defaults: defaults,
      oldApp: oldApp,
      isRunning: { _, _ in true },
      prompt: prompt,
      recycler: recycler
    )

    controller.checkAndOfferMigration()

    #expect(prompt.callCount == 1)
    #expect(prompt.runningStates == [true])
    #expect(recycler.recycledURLs.isEmpty)
    #expect(!defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))
  }

  @Test
  func wrongBundleIdentifierAndUnbundledCopyAreIgnored() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let prompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let recycler = TestMigrationRecycler()
    let controller = makeController(
      defaults: defaults,
      oldApp: oldApp,
      bundleIdentifier: { _ in "com.example.unrelated" },
      prompt: prompt,
      recycler: recycler
    )

    controller.checkAndOfferMigration()

    #expect(prompt.callCount == 0)
    #expect(recycler.recycledURLs.isEmpty)
    #expect(
      !CodexetineUpgradeMigrationController.isInstalledCodexetineBundle(
        URL(filePath: "/Users/tester/Downloads/Codexetine.app")
      ))
  }

  private func makeController(
    defaults: UserDefaults,
    oldApp: URL,
    bundleIdentifier: @escaping (URL) -> String? = { _ in
      CodexetineUpgradeMigrationController.legacyBundleIdentifier
    },
    isRunning: @escaping @MainActor (URL, String) -> Bool = { _, _ in false },
    prompt: TestMigrationPrompt,
    recycler: TestMigrationRecycler
  ) -> CodexetineUpgradeMigrationController {
    CodexetineUpgradeMigrationController(
      defaults: defaults,
      currentBundleURL: URL(filePath: "/Applications/Codexetine.app"),
      legacyBundleURL: oldApp,
      bundleIdentifier: bundleIdentifier,
      isRunning: isRunning,
      prompt: prompt,
      recycler: recycler
    )
  }

  @Test
  func delayedSuccessfulRecycleKeepsControllerAliveUntilCompletion() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let prompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let recycler = TestMigrationRecycler(autoComplete: false)
    weak var weakController: CodexetineUpgradeMigrationController?
    do {
      let controller = makeController(
        defaults: defaults,
        oldApp: oldApp,
        prompt: prompt,
        recycler: recycler
      )
      weakController = controller
      controller.checkAndOfferMigration()
      #expect(weakController != nil)
      #expect(defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))
      recycler.finish(true)
    }

    #expect(defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))
    #expect(recycler.recycledURLs == [oldApp.standardizedFileURL])
  }

  @Test
  func delayedFailedRecycleResetsBookkeepingAndAllowsExplicitRetry() throws {
    let defaults = try makeDefaults()
    let oldApp = try makeLegacyBundle()
    defer {
      defaults.removePersistentDomain(forName: defaultsSuiteName(defaults))
      try? FileManager.default.removeItem(at: oldApp)
    }

    let firstPrompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let firstRecycler = TestMigrationRecycler(autoComplete: false)
    let firstController = makeController(
      defaults: defaults,
      oldApp: oldApp,
      prompt: firstPrompt,
      recycler: firstRecycler
    )
    firstController.checkAndOfferMigration()
    firstRecycler.finish(false)
    #expect(!defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))

    let retryPrompt = TestMigrationPrompt(choice: .moveOldAppToTrash)
    let retryRecycler = TestMigrationRecycler()
    let retryController = makeController(
      defaults: defaults,
      oldApp: oldApp,
      prompt: retryPrompt,
      recycler: retryRecycler
    )
    retryController.checkAndOfferMigration()

    #expect(retryPrompt.callCount == 1)
    #expect(retryRecycler.recycledURLs == [oldApp.standardizedFileURL])
    #expect(defaults.bool(forKey: CodexetineUpgradeMigrationController.promptShownKey))
  }

  private func makeLegacyBundle() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: "Codexetine.LegacyMigrationTests.\(UUID().uuidString).app")
    try FileManager.default.createDirectory(
      at: url.appending(path: "Contents"),
      withIntermediateDirectories: true
    )
    return url
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "CodexNotSleep.AppUpgradeMigrationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.set(suiteName, forKey: Self.suiteNameKey)
    return defaults
  }

  private func defaultsSuiteName(_ defaults: UserDefaults) -> String {
    defaults.string(forKey: Self.suiteNameKey)!
  }

  private static let suiteNameKey = "CodexNotSleep.AppUpgradeMigrationTests.suiteName"
}

@MainActor
private final class TestMigrationPrompt: CodexetineMigrationPrompting {
  let choice: CodexetineMigrationChoice
  private(set) var callCount = 0
  private(set) var runningStates: [Bool] = []

  init(choice: CodexetineMigrationChoice) {
    self.choice = choice
  }

  func choose(oldAppURL: URL, isRunning: Bool) -> CodexetineMigrationChoice {
    callCount += 1
    runningStates.append(isRunning)
    return choice
  }
}

@MainActor
private final class TestMigrationRecycler: CodexetineMigrationRecycling {
  private(set) var recycledURLs: [URL] = []
  private let autoComplete: Bool
  private var completion: (@MainActor @Sendable (Bool) -> Void)?

  init(autoComplete: Bool = true) {
    self.autoComplete = autoComplete
  }

  func recycle(
    _ url: URL,
    completion: @escaping @MainActor @Sendable (Bool) -> Void
  ) {
    recycledURLs.append(url.standardizedFileURL)
    if autoComplete {
      completion(true)
    } else {
      self.completion = completion
    }
  }

  func finish(_ succeeded: Bool) {
    let completion = self.completion
    self.completion = nil
    completion?(succeeded)
  }
}
