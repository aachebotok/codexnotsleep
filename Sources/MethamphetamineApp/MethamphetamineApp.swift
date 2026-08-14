import SwiftUI

@MainActor
final class MethamphetamineApplicationDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CommandLine.arguments.contains("--preview-power-protect-prompt") else { return }
    _ = NSAppleScriptPowerProtectAuthorizationRunner().run(
      script: PowerProtectInstaller.authorizationPreviewAppleScript
    )
    NSApplication.shared.terminate(nil)
  }
}

@main
struct MethamphetamineApplication: App {
  @NSApplicationDelegateAdaptor(MethamphetamineApplicationDelegate.self)
  private var applicationDelegate
  @StateObject private var controller: AppController

  init() {
    let isPromptPreview = CommandLine.arguments.contains("--preview-power-protect-prompt")
    _controller = StateObject(
      wrappedValue: AppController(startsAutomatically: !isPromptPreview)
    )
  }

  var body: some Scene {
    MenuBarExtra {
      MenuContentView(controller: controller)
    } label: {
      MenuBarCapsuleIcon(showsIssue: controller.showsMenuIssue)
        .accessibilityLabel("Methamphetamine: \(controller.statusTitle)")
    }
    .menuBarExtraStyle(.window)
    .windowResizability(.contentSize)
  }
}
