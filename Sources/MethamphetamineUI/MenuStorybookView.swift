import SwiftUI

public struct MenuStorybookView: View {
  private let columns = [
    GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .top)
  ]

  public init() {}

  public var body: some View {
    ScrollView {
      LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
        ForEach(MenuStorybookScenario.all) { scenario in
          MenuStorybookCard(scenario: scenario)
        }
      }
      .padding(24)
    }
    .navigationTitle("Methamphetamine Storybook")
    .frame(minWidth: 760, minHeight: 640)
  }
}
