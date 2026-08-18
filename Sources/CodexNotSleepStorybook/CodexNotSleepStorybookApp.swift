import CodexNotSleepUI
import SwiftUI

@main
struct CodexNotSleepStorybookApplication: App {
  var body: some Scene {
    WindowGroup("Codex Not Sleep Storybook") {
      MenuStorybookView()
    }
    .defaultSize(width: 900, height: 760)
  }
}
