import AppKit

@MainActor
final class CodexNotSleepMenuBarController: NSObject, NSMenuDelegate {
  private let controller: AppController
  private var statusItem: NSStatusItem?
  private let menu = NSMenu()
  private let stayAwakeItem = NSMenuItem(
    title: "Stay Awake",
    action: #selector(toggleProtection(_:)),
    keyEquivalent: ""
  )
  private let closedLidItem = NSMenuItem(
    title: "Keep Awake with Lid Closed",
    action: #selector(toggleClosedLid(_:)),
    keyEquivalent: ""
  )
  private let issueItem = NSMenuItem(
    title: "",
    action: #selector(resolveIssue(_:)),
    keyEquivalent: ""
  )
  private let issueSeparator = NSMenuItem.separator()
  private let quitItem = NSMenuItem(
    title: "Quit",
    action: #selector(quit(_:)),
    keyEquivalent: "q"
  )

  init(controller: AppController) {
    self.controller = controller
    super.init()
  }

  func install() {
    NSApplication.shared.setActivationPolicy(.accessory)

    menu.delegate = self
    menu.autoenablesItems = false
    stayAwakeItem.target = self
    closedLidItem.target = self
    issueItem.target = self
    quitItem.target = self
    quitItem.keyEquivalentModifierMask = [.command]

    menu.addItem(stayAwakeItem)
    menu.addItem(closedLidItem)
    menu.addItem(.separator())
    menu.addItem(issueItem)
    menu.addItem(issueSeparator)
    menu.addItem(quitItem)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "CodexNotSleepStatusItem"
    item.menu = menu
    item.isVisible = true
    statusItem = item

    guard let button = item.button else {
      NSLog("Codexetine: status item button was not created")
      return
    }

    let image = NSImage(
      systemSymbolName: AppController.menuIconName,
      accessibilityDescription: "Codexetine"
    )
    image?.isTemplate = true
    button.image = image
    button.imageScaling = .scaleProportionallyDown
    button.imagePosition = .imageOnly
    button.toolTip = "Codexetine"
    updateMenu()
  }

  func menuWillOpen(_ menu: NSMenu) {
    controller.menuDidOpen()
    updateMenu()
  }

  func menuNeedsUpdate(_ menu: NSMenu) {
    updateMenu()
  }

  private func updateMenu() {
    stayAwakeItem.state = controller.isProtectionEnabled ? .on : .off
    stayAwakeItem.isEnabled = !controller.isPreparingProtection

    if let closedLidTitle = controller.closedLidMenuTitle {
      closedLidItem.title = closedLidTitle
      closedLidItem.state = controller.isClosedLidEnabled ? .on : .off
      closedLidItem.isHidden = false
      closedLidItem.isEnabled = !controller.isPreparingClosedLid
    } else {
      closedLidItem.isHidden = true
    }

    if let issue = controller.menuIssue {
      issueItem.title = issue.title
      issueItem.isHidden = false
      issueSeparator.isHidden = false
      issueItem.isEnabled = !controller.isResolvingIssue
    } else {
      issueItem.isHidden = true
      issueSeparator.isHidden = true
    }
  }

  @objc private func toggleProtection(_ sender: Any?) {
    controller.setProtectionEnabled(!controller.isProtectionEnabled)
    updateMenu()
  }

  @objc private func resolveIssue(_ sender: Any?) {
    controller.resolveMenuIssue()
    updateMenu()
  }

  @objc private func toggleClosedLid(_ sender: Any?) {
    controller.toggleClosedLidProtection()
    updateMenu()
  }

  @objc private func quit(_ sender: Any?) {
    controller.quit()
  }
}

@MainActor
final class CodexNotSleepApplicationDelegate: NSObject, NSApplicationDelegate {
  private var menuBarController: CodexNotSleepMenuBarController?

  func applicationDidFinishLaunching(_ notification: Notification) {
    if CommandLine.arguments.contains("--preview-power-protect-prompt") {
      _ = NSAppleScriptPowerProtectAuthorizationRunner().run(
        script: PowerProtectInstaller.authorizationPreviewAppleScript
      )
      NSApplication.shared.terminate(nil)
      return
    }

    let controller = AppController(startsAutomatically: true)
    let menuBarController = CodexNotSleepMenuBarController(controller: controller)
    menuBarController.install()
    self.menuBarController = menuBarController
  }
}

@main
struct CodexNotSleepApplication {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = CodexNotSleepApplicationDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
  }
}
