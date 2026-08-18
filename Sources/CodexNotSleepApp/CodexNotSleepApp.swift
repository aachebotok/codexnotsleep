import AppKit
import SwiftUI

enum MenuBarPopoverMetrics {
  static let contentSize = NSSize(width: 320, height: 126)
  static let verticalGap: CGFloat = 4

  @MainActor
  static func positioningRect(for button: NSStatusBarButton) -> NSRect {
    let imageRect = button.cell?.imageRect(forBounds: button.bounds) ?? button.bounds
    guard imageRect.width > 0, imageRect.height > 0 else {
      return button.bounds
    }

    return imageRect
  }

  static func alignedWindowFrame(
    popoverFrame: NSRect,
    statusItemFrame: NSRect
  ) -> NSRect {
    var frame = popoverFrame
    frame.origin.y = statusItemFrame.minY - verticalGap - frame.height
    return frame
  }
}

@MainActor
final class CodexNotSleepMenuBarController: NSObject {
  private let controller: AppController
  private var statusItem: NSStatusItem?
  private let popover: NSPopover

  init(controller: AppController) {
    self.controller = controller
    popover = NSPopover()
    super.init()

    let hostingController = NSHostingController(
      rootView: MenuContentView(controller: controller)
    )
    popover.contentViewController = hostingController
    popover.behavior = .transient
    popover.animates = true
    popover.contentSize = MenuBarPopoverMetrics.contentSize
  }

  func install() {
    // Keep the app as a menu-bar accessory. This is also required for macOS 26
    // to register the status item with Control Center consistently.
    NSApplication.shared.setActivationPolicy(.accessory)

    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    item.autosaveName = "CodexNotSleepStatusItem"
    item.isVisible = true
    statusItem = item

    guard let button = item.button else {
      NSLog("Codex Not Sleep: status item button was not created")
      return
    }
    let symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: 16,
      weight: .bold
    )
    let image = NSImage(
      systemSymbolName: AppController.menuIconName,
      accessibilityDescription: "Codex Not Sleep"
    )?.withSymbolConfiguration(symbolConfiguration)
    if image == nil {
      NSLog("Codex Not Sleep: menu-bar symbol was not available")
    }
    image?.isTemplate = true
    button.image = image
    button.imageScaling = .scaleProportionallyDown
    button.imagePosition = .imageOnly
    button.toolTip = "Codex Not Sleep"
    button.target = self
    button.action = #selector(togglePopover(_:))
    NSLog("Codex Not Sleep: status item installed (image: %@)", image == nil ? "no" : "yes")
  }

  @objc private func togglePopover(_ sender: Any?) {
    guard let button = statusItem?.button else { return }
    controller.menuDidOpen()

    if popover.isShown {
      popover.performClose(sender)
    } else {
      // Anchor the arrow to the visible SF Symbol, not to the full-height
      // status button. This keeps the panel optically close to the icon on
      // menu bars with enlarged Liquid Glass hit areas.
      let positioningRect = MenuBarPopoverMetrics.positioningRect(for: button)
      popover.show(
        relativeTo: positioningRect,
        of: button,
        preferredEdge: .minY
      )
      alignPopoverWindow(to: button)

      // NSPopover may apply its own placement again while starting the show
      // animation, so repeat the same deterministic alignment next run loop.
      DispatchQueue.main.async { [weak self, weak button] in
        guard let self, let button else { return }
        self.alignPopoverWindow(to: button)
      }
    }
  }

  private func alignPopoverWindow(to button: NSStatusBarButton) {
    guard
      let statusItemWindow = button.window,
      let popoverWindow = popover.contentViewController?.view.window
    else {
      return
    }

    let buttonFrameInWindow = button.convert(button.bounds, to: nil)
    let buttonFrameOnScreen = statusItemWindow.convertToScreen(buttonFrameInWindow)
    let alignedFrame = MenuBarPopoverMetrics.alignedWindowFrame(
      popoverFrame: popoverWindow.frame,
      statusItemFrame: buttonFrameOnScreen
    )
    popoverWindow.setFrame(alignedFrame, display: true)
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
