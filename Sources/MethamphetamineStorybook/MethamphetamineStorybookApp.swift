import MethamphetamineUI
import SwiftUI

@main
struct MethamphetamineStorybookApplication: App {
  var body: some Scene {
    WindowGroup("Methamphetamine Storybook") {
      MenuStorybookView()
    }
    .defaultSize(width: 900, height: 760)
  }
}
