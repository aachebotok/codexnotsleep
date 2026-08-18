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
    VStack(alignment: .leading, spacing: 0) {
      if let issue {
        MenuIssueView(
          issue: issue,
          isResolving: isResolvingIssue,
          action: issueAction
        )
      } else {
        HStack(alignment: .center, spacing: 16) {
          VStack(alignment: .leading, spacing: 1) {
            Text("Stay awake")
              .font(.title3)
            Text("While Codex is working")
              .font(.body)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)

          Toggle("Stay awake", isOn: $isProtectionEnabled)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.large)
            .disabled(isPreparingProtection)
        }
        .accessibilityHint("Prevents your Mac from sleeping during an active Codex task")
      }

      Divider()
        .padding(.vertical, 6)

      Button(action: quitAction) {
        Text("Quit")
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .buttonStyle(.borderless)
      .controlSize(.small)
      .accessibilityHint("Quits Codex Not Sleep and restores normal sleep")
    }
    .frame(minWidth: 296, alignment: .leading)
    .padding(.horizontal, 12)
    .padding(.vertical, 12)
    .modifier(WindowMenuBackground())
  }
}

private struct WindowMenuBackground: ViewModifier {
  func body(content: Content) -> some View {
    if #available(macOS 15.0, *) {
      content.containerBackground(.windowBackground, for: .window)
    } else {
      content
    }
  }
}
