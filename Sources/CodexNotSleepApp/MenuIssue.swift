import Foundation

enum MenuIssue: Equatable {
  case permissionRequired
  case sleepRestoreRequired

  var title: String {
    switch self {
    case .permissionRequired:
      "Use with lid closed"
    case .sleepRestoreRequired:
      "Fix sleep issue"
    }
  }
}
