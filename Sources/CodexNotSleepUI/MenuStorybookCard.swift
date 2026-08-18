import SwiftUI

struct MenuStorybookCard: View {
  let scenario: MenuStorybookScenario
  @State private var isProtectionEnabled: Bool

  init(scenario: MenuStorybookScenario) {
    self.scenario = scenario
    _isProtectionEnabled = State(initialValue: scenario.state.isProtectionEnabled)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(scenario.title)
          .font(.headline)
        Text(scenario.note)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      MenuPanelView(
        isProtectionEnabled: $isProtectionEnabled,
        isPreparingProtection: scenario.state.isPreparingProtection,
        issue: scenario.state.issue,
        isResolvingIssue: scenario.state.isResolvingIssue,
        issueAction: {},
        quitAction: {}
      )
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(.separator)
      }
    }
    .padding(16)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
  }
}
