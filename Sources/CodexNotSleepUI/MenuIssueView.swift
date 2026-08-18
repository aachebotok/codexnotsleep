import SwiftUI

struct MenuIssueView: View {
  let issue: MenuIssue
  let isResolving: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text(issue.title)
            .font(.body)

          Text(issue.message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        if isResolving {
          ProgressView()
            .controlSize(.small)
            .accessibilityLabel("In progress")
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .controlSize(.regular)
    .disabled(isResolving)
    .accessibilityHint(issue.message)
  }
}
