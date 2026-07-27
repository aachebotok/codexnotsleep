import SwiftUI

public struct MenuPanelView: View {
  @Binding var isProtectionEnabled: Bool
  let isPreparingProtection: Bool
  let issue: MenuIssue?
  let isResolvingIssue: Bool
  let issueAction: () -> Void
  let quitAction: () -> Void

  public init(
    isProtectionEnabled: Binding<Bool>,
    isPreparingProtection: Bool,
    issue: MenuIssue?,
    isResolvingIssue: Bool,
    issueAction: @escaping () -> Void,
    quitAction: @escaping () -> Void
  ) {
    _isProtectionEnabled = isProtectionEnabled
    self.isPreparingProtection = isPreparingProtection
    self.issue = issue
    self.isResolvingIssue = isResolvingIssue
    self.issueAction = issueAction
    self.quitAction = quitAction
  }

  public var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let issue {
        MenuIssueView(
          issue: issue,
          isResolving: isResolvingIssue,
          action: issueAction
        )
      } else {
        Toggle(isOn: $isProtectionEnabled) {
          VStack(alignment: .leading, spacing: 2) {
            Text("Stay awake")
              .font(.system(size: 15))
            Text("While Codex is working")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(isPreparingProtection)
        .accessibilityHint("Prevents your Mac from sleeping during an active Codex task")
      }

      Divider()
        .padding(.top, 8)
        .padding(.bottom, 6)

      Button("Quit", action: quitAction)
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .accessibilityHint("Quits Methamphetamine and restores normal sleep")
    }
    .frame(width: 288, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }
}
