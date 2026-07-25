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
            Text("Не спать")
              .font(.system(size: 15))
            Text("Пока работает Codex")
              .font(.system(size: 13))
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .disabled(isPreparingProtection)
        .accessibilityHint("Mac не засыпает во время активной задачи Codex")
      }

      Divider()
        .padding(.top, 8)
        .padding(.bottom, 6)

      Button("Выйти", action: quitAction)
        .buttonStyle(.plain)
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
        .accessibilityHint("Закрывает Methamphetamine и возвращает обычный режим сна")
    }
    .frame(width: 288, alignment: .leading)
    .padding(.horizontal, 14)
    .padding(.top, 14)
    .padding(.bottom, 12)
  }
}
