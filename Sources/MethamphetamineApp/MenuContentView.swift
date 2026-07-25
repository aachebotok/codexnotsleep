import SwiftUI
import MethamphetamineUI

struct MenuContentView: View {
  @ObservedObject var controller: AppController

  private var protectionBinding: Binding<Bool> {
    Binding(
      get: { controller.isProtectionEnabled },
      set: { controller.setProtectionEnabled($0) }
    )
  }

  var body: some View {
    MenuPanelView(
      isProtectionEnabled: protectionBinding,
      isPreparingProtection: controller.isPreparingProtection,
      issue: controller.menuIssue,
      isResolvingIssue: controller.isResolvingIssue,
      issueAction: controller.resolveMenuIssue,
      quitAction: { NSApplication.shared.terminate(nil) }
    )
    .onAppear(perform: controller.menuDidOpen)
  }
}
