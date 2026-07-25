import SwiftUI

struct MenuIssueView: View {
  let issue: MenuIssue
  let isResolving: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack(spacing: 12) {
        VStack(alignment: .leading, spacing: 2) {
          Text(issue.title)
            .font(.system(size: 15))

          Text(issue.message)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isResolving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("Выполняется")
        } else {
          Image(systemName: "chevron.right")
            .font(.caption)
            .bold()
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(isResolving)
    .accessibilityHint(issue.message)
  }
}
